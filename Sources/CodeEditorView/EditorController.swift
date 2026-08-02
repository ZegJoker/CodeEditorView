import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import CoreGraphics
import Foundation
import Observation
import TextStory

/// Central editor model: document, layout, multi-range selection, undo, emphasis, and event streams.
@MainActor
@Observable
public final class EditorController {
    /// Shared content authority (versioned text + document-scoped undo).
    public let textDocument: TextDocument
    /// Presentation session (selection / scroll / find). Nil for simple single-controller hosts
    /// that only use the controller’s selection APIs.
    public private(set) var session: EditorSession?
    /// Buffer used by layout, typesetting, and highlighting.
    ///
    /// When sharing a document across controllers this is a **session-local mirror** so themes
    /// and syntax attributes stay independent. Otherwise it is `textDocument.store`.
    public private(set) var document: DocumentStore
    public let layout: LayoutEngine
    public let selection: SelectionEngine
    /// Document-scoped undo (always `textDocument.undo`).
    public var undoCoordinator: UndoCoordinator { textDocument.undo }
    public let events: EditorEventStream
    public let emphasis: EmphasisManager

    /// Optional command dispatcher (built-ins installed via ``installBuiltInCommands(into:)``).
    public var commandDispatcher: CommandDispatcher?
    /// Token retaining built-in command registrations.
    var builtInCommandRegistration: (any CommandDisposable)?

    /// Observation task for shared-document remote edits.
    /// Stored as nonisolated so `deinit` can cancel without MainActor hopping.
    nonisolated(unsafe) var documentObservationTask: Task<Void, Never>?
    /// Last transaction id applied locally (skip remote echo).
    var lastLocalTransactionID: UUID?
    /// Watermark for remote sync.
    var lastSeenDocumentVersion: DocumentVersion = .zero
    /// True while applying a remote shared-document edit.
    var isApplyingRemoteDocumentEdit = false

    public var configuration: EditorConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            applyConfiguration(old: oldValue)
        }
    }

    public var invisibleCharactersDelegate: InvisibleCharactersDelegate? {
        didSet {
            // hosts redraw
        }
    }

    /// Two-way UI state (cursors, scroll, find panel fields).
    public var editorState: EditorState = .empty

    /// Find / replace session (panel visibility, query, matches).
    public let findSession = FindSession()

    /// Hosts observe to show/hide panel chrome and refresh find UI.
    public var onFindSessionChange: (() -> Void)?

    /// Code completion session (items, selection, visibility).
    public let completionSession = CompletionSession()

    /// App-supplied completion provider (weak; host must retain the delegate).
    public weak var completionDelegate: (any CodeSuggestionDelegate)?

    /// App-supplied jump-to-definition provider (weak; host must retain the delegate).
    public weak var jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)? {
        didSet {
            if jumpToDefinitionDelegate == nil {
                cancelJumpHover()
            }
        }
    }

    /// Strong retain for adapters installed via ``installLanguageServices(_:context:)``.
    var languageServicesRetain: AnyObject?

    /// Hosts observe to present/update the completion panel UI.
    public var onCompletionSessionChange: (() -> Void)?
    /// Blocks nested `notifyCompletionSessionChange` (panel sync ↔ selection feedback).
    var isNotifyingCompletionSessionChange = false

    /// In-flight async completion load (cancelled on re-open/hide).
    var completionRequestTask: Task<Void, Never>?

    /// Jump-to-definition model (Phase 11).
    let _jumpToDefinitionModel = JumpToDefinitionModel()
    var _onJumpFailed: (() -> Void)?
    var _onRequestScrollToSelection: (() -> Void)?

    /// Line annotations / diagnostics (Phase 12).
    let _annotationStore = LineAnnotationStore()
    /// Fold/annotation updates deferred until the layout transaction ends (avoids typeset OOB).
    var pendingPostEditSideEffects: [(range: NSRange, delta: Int)] = []

    /// Line folding model (Phase 10).
    let _foldModel = LineFoldModel()
    var _foldingInstalled = false
    /// Selected fold placeholder id (Xcode first-click selection).
    public internal(set) var selectedFoldPlaceholderID: FoldRange.FoldIdentifier?
    /// Fold animation progress 0...1 (hosts may use for polish).
    public internal(set) var foldAnimationProgress: CGFloat = 1
    var foldAnimationTask: Task<Void, Never>?

    /// Width of the line-number gutter (0 when hidden).
    public private(set) var gutterWidth: CGFloat = 0

    /// Coordinators receive lifecycle/edit callbacks (no Combine).
    public private(set) var coordinators: [any EditorCoordinator] = []

    /// Versioned lifecycle observers (preferred over ``EditorCoordinator`` for new code).
    public private(set) var lifecycleObservers: [any EditorLifecycleObserver] = []
    var weakLifecycleObservers: [WeakLifecycleObserver] = []

    /// Syntax highlight providers (regex, tree-sitter, …).
    public private(set) var highlightProviders: [any HighlightProviding] = []

    /// Active highlighter (always present; idle when no providers).
    public private(set) var highlighter: Highlighter!

    /// Prevents `language` ↔ `languageID` didSet from re-entering reconfigure.
    private var isUpdatingLanguage = false

    /// Language id for providers (e.g. `"swift"`, `"json"`).
    public var languageID: String? {
        didSet {
            guard languageID != oldValue, !isUpdatingLanguage else { return }
            isUpdatingLanguage = true
            defer { isUpdatingLanguage = false }
            if language?.id.rawValue != languageID {
                language = languageID.flatMap { CodeLanguages.language(id: $0) }
                // `language` didSet runs reconfigure when not suppressed.
            } else {
                highlighter?.setLanguageID(languageID)
            }
        }
    }

    /// Structured language (preferred over raw `languageID`).
    public var language: CodeLanguage? {
        didSet {
            guard language != oldValue else { return }
            let newID = language?.id.rawValue
            if !isUpdatingLanguage, languageID != newID {
                isUpdatingLanguage = true
                languageID = newID
                isUpdatingLanguage = false
            }
            reconfigureLanguageHighlighting()
        }
    }

    /// Cancels in-flight language loads so a later switch cannot re-parse stale buffer text.
    private var languageConfigTask: Task<Void, Never>?
    private var languageConfigGeneration: UInt64 = 0

    /// Reinstalls language-driven tree-sitter highlighting (e.g. after turning Regex mode off).
    /// Safe to call when the language did not change — unlike setting ``language`` again.
    public func restoreLanguageHighlighting() {
        // Drop host-installed providers (regex, etc.) and rebuild tree-sitter for the current language.
        let hasCustom = highlightProviders.contains { !($0 is TreeSitterHighlightProvider) }
        if hasCustom {
            setHighlightProviders([])
        }
        reconfigureLanguageHighlighting()
    }

    /// True while a language grammar is loading — full-text replaces skip extra bootstraps
    /// (the language task will re-bootstrap once with the final buffer).
    var languageConfigInFlight = false

    private func reconfigureLanguageHighlighting() {
        // Auto-manage tree-sitter when the app didn't install custom non-TS providers.
        let hasCustomProviders = highlightProviders.contains { !($0 is TreeSitterHighlightProvider) }
        if hasCustomProviders {
            // Regex (or other host) mode: do not start tree-sitter loads that can race the UI.
            highlighter?.setLanguageID(language?.id.rawValue)
            document.resetAttributesToDefaults()
            highlighter?.invalidateAll()
            onNeedsDisplay?()
            return
        }

        languageConfigTask?.cancel()
        languageConfigGeneration &+= 1
        let gen = languageConfigGeneration

        // Plain text / nil language: tear down highlighting immediately and cheaply.
        guard let language, language.id != .plainText else {
            languageConfigInFlight = false
            // Drop providers without waiting for any in-flight grammar load.
            setHighlightProviders([])
            onNeedsDisplay?()
            return
        }

        languageConfigInFlight = true

        // Drop previous language colors immediately so a slow load cannot leave mixed runs.
        document.resetAttributesToDefaults()
        onNeedsDisplay?()

        // Reuse an existing tree-sitter provider and load the new grammar off-main-thread.
        // Creating + compiling queries synchronously on MainActor freezes the UI (ANR on language switch).
        if let existing = highlightProviders.compactMap({ $0 as? TreeSitterHighlightProvider }).first {
            let target = language
            languageConfigTask = Task { [weak self] in
                // Let SwiftUI finish updateNSView before we touch the provider.
                await Task.yield()
                guard let self else { return }

                let stillCurrent = await MainActor.run {
                    gen == self.languageConfigGeneration && self.language?.id == target.id
                }
                guard stillCurrent else {
                    await MainActor.run {
                        if gen == self.languageConfigGeneration {
                            self.languageConfigInFlight = false
                        }
                    }
                    return
                }

                // loadAsync compiles off-main; do not hold other UI work on this path.
                await existing.loadAsync(language: target)

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if gen == self.languageConfigGeneration {
                        self.languageConfigInFlight = false
                    }
                    guard gen == self.languageConfigGeneration, self.language?.id == target.id else { return }

                    // Single bootstrap: re-read live document after any concurrent `text =` updates.
                    self.highlighter?.updateHooks(self.makeHighlightHooks())
                    self.highlighter?.applyLanguageID(target.id.rawValue)
                    self.layout.invalidateAll()
                    self.onNeedsDisplay?()
                }
            }
            return
        }

        languageConfigInFlight = false
        if let provider = TreeSitterHighlightProvider.make(for: language) {
            setHighlightProviders([provider])
        } else {
            setHighlightProviders([])
        }
    }

    /// Hosts set this to trigger redraw after highlight paints.
    public var onNeedsDisplay: (() -> Void)?

    /// Hosts set this to mirror document text into SwiftUI/`@State` (and other) bindings.
    /// Called from every successful edit path via ``publishTextChange``.
    public var onTextDidChange: ((String) -> Void)?

    /// Hosts set this to mirror selection into SwiftUI/`@State` bindings.
    /// Required for controller-driven navigation (find, jump-to-definition) so
    /// `updateNSView` cannot re-apply a stale host selection.
    public var onSelectionDidChange: ((NSRange) -> Void)?

    private var weakCoordinators: [WeakCoordinator] = []
    private let bracketEmphasisGroup = EmphasisGroup.bracketPairs
    /// Suppress re-entrant find while applying a replace from the find session.
    var isApplyingFindReplace = false

    /// Observable full document string.
    public var text: String {
        get { document.fullString }
        set {
            guard newValue != document.fullString else { return }
            replaceFullText(newValue)
        }
    }

    public var selectedRange: NSRange {
        get { selection.selectedRange }
        set { setSelectedRange(newValue) }
    }

    public var selectedRanges: [NSRange] {
        get { selection.selectedRanges }
        set { setSelectedRanges(newValue) }
    }

    public private(set) var contentSize: CGSize = .zero
    public private(set) var latestSnapshot: LayoutSnapshot = .empty
    /// Suggested scroll target after edits/navigation (hosts may consume).
    public private(set) var scrollTarget: CGRect?

    public var textChanges: AsyncStream<String> { events.makeTextStream() }
    public var selectionChanges: AsyncStream<[NSRange]> { events.makeSelectionStream() }
    public var editorEvents: AsyncStream<EditorEvent> { events.makeEventStream() }

    /// Creates a standalone controller with a private ``TextDocument`` (legacy-friendly).
    public convenience init(
        text: String = "",
        configuration: EditorConfiguration = EditorConfiguration(),
        coordinators: [any EditorCoordinator] = [],
        highlightProviders: [any HighlightProviding] = [],
        language: CodeLanguage? = nil,
        languageID: String? = nil
    ) {
        let doc = TextDocument(text: text)
        self.init(
            document: doc,
            session: nil,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language,
            languageID: languageID,
            sharePresentation: false
        )
    }

    /// Creates a controller attached to a shared document and presentation session.
    ///
    /// When multiple controllers share the same ``TextDocument``, each uses a
    /// session-local presentation buffer so themes and syntax paint stay independent.
    public convenience init(
        document: TextDocument,
        session: EditorSession,
        configuration: EditorConfiguration = EditorConfiguration(),
        coordinators: [any EditorCoordinator] = [],
        highlightProviders: [any HighlightProviding] = [],
        language: CodeLanguage? = nil,
        languageID: String? = nil
    ) {
        precondition(session.documentID == document.id, "EditorSession.documentID must match TextDocument.id")
        self.init(
            document: document,
            session: session,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language,
            languageID: languageID,
            sharePresentation: true
        )
    }

    private init(
        document textDocument: TextDocument,
        session: EditorSession?,
        configuration: EditorConfiguration,
        coordinators: [any EditorCoordinator],
        highlightProviders: [any HighlightProviding],
        language: CodeLanguage?,
        languageID: String?,
        sharePresentation: Bool
    ) {
        self.configuration = configuration
        let resolvedLanguage = language ?? languageID.flatMap { CodeLanguages.language(id: $0) }
        self.language = resolvedLanguage
        self.languageID = resolvedLanguage?.id.rawValue ?? languageID
        self.textDocument = textDocument
        self.session = session
        if sharePresentation {
            // Session-local mirror: same plain text, independent attributes.
            self.document = DocumentStore(
                string: textDocument.text,
                attributes: configuration.typingAttributes
            )
        } else {
            textDocument.store.defaultAttributes = configuration.typingAttributes
            self.document = textDocument.store
        }
        self.layout = LayoutEngine()
        self.selection = SelectionEngine()
        self.events = EditorEventStream()
        self.emphasis = EmphasisManager()
        self.lastSeenDocumentVersion = textDocument.version

        layout.attach(document: document, typingAttributes: configuration.typingAttributes)
        selection.attach(document: document, layout: layout)
        // Fold/annotation work must run only after the line index matches the document.
        // Running it mid-transaction left stale utf16 ranges → typeset attributedSubstring crash.
        layout.onTransactionEnded = { [weak self] in
            self?.flushPostEditSideEffects()
        }
        emphasis.onChange = { [weak self] in
            self?.events.yield(.selectionDidChange)
        }
        if configuration.showInvisibleCharacters {
            invisibleCharactersDelegate = DefaultInvisibleCharactersDelegate()
        }
        applyConfiguration(old: nil)
        setCoordinators(coordinators)

        if let session {
            selection.setSelectedRanges(session.selectedNSRanges)
        }

        highlighter = Highlighter(hooks: makeHighlightHooks())
        highlighter.setLanguageID(self.languageID)

        if !highlightProviders.isEmpty {
            setHighlightProviders(highlightProviders)
        } else if let resolvedLanguage, let provider = TreeSitterHighlightProvider.make(for: resolvedLanguage) {
            setHighlightProviders([provider])
        }

        installFoldingIfNeeded()
        installJumpToDefinitionIfNeeded()
        startObservingSharedDocumentIfNeeded()

        // Default command dispatcher with built-in edit/find/completion actions.
        let dispatcher = CommandDispatcher()
        builtInCommandRegistration = installBuiltInCommands(into: dispatcher)

        // Auto-evaluate large-file mode on load (UI-N09) — never require a manual refresh.
        refreshLargeFileMode()
    }

    deinit {
        // Tasks capturing self are cancelled when the controller is released.
        documentObservationTask?.cancel()
    }

    // MARK: - Highlighting

    public func setHighlightProviders(_ providers: [any HighlightProviding]) {
        highlightProviders = providers
        highlighter?.updateHooks(makeHighlightHooks())
        highlighter?.setProviders(providers)
    }

    /// Call from hosts when the visible document UTF-16 range changes.
    public func setVisibleUTF16RangeForHighlighting(_ range: NSRange) {
        guard let highlighter else { return }
        guard largeFileMode.syntaxHighlightingEnabled else {
            highlighter.isSuspended = true
            highlighter.cancelPendingWork()
            return
        }
        highlighter.updateHooks(makeHighlightHooks())
        highlighter.setVisibleUTF16Range(range)
    }

    /// Convenience: map a layout snapshot’s fragments to a UTF-16 highlight window.
    public func updateHighlighting(for snapshot: LayoutSnapshot) {
        guard largeFileMode.syntaxHighlightingEnabled else {
            highlighter?.isSuspended = true
            highlighter?.cancelPendingWork()
            return
        }
        guard !snapshot.fragments.isEmpty else {
            // Large docs still restrict to a bounded window when feasible (UI-N09).
            let len = document.length
            let window = min(len, 8_192)
            setVisibleUTF16RangeForHighlighting(NSRange(location: 0, length: window))
            return
        }
        var minLoc = Int.max
        var maxEnd = 0
        for item in snapshot.fragments {
            let r = item.fragment.documentRange
            minLoc = min(minLoc, r.location)
            maxEnd = max(maxEnd, r.location + r.length)
        }
        if minLoc == Int.max {
            setVisibleUTF16RangeForHighlighting(NSRange(location: 0, length: document.length))
        } else {
            setVisibleUTF16RangeForHighlighting(NSRange(location: minLoc, length: max(0, maxEnd - minLoc)))
        }
    }

    func makeHighlightHooks() -> Highlighter.DocumentHooks {
        Highlighter.DocumentHooks(
            length: { [weak self] in self?.document.length ?? 0 },
            substring: { [weak self] range in self?.document.substring(from: range) },
            setAttributes: { [weak self] attrs, range in
                self?.document.setAttributes(attrs, range: range)
            },
            typingAttributes: { [weak self] in self?.configuration.typingAttributes ?? [:] },
            theme: { [weak self] in self?.configuration.theme ?? .default },
            font: { [weak self] in self?.configuration.font ?? PlatformDefaults.monospacedFont },
            invalidateLayout: { [weak self] range in
                self?.layout.invalidateTypeset(in: range)
            },
            needsDisplay: { [weak self] in
                self?.onNeedsDisplay?()
            },
            version: { [weak self] in self?.textDocument.version ?? .zero }
        )
    }

    func noteWillEdit(_ range: NSRange) {
        highlighter?.willApplyEdit(range: range)
    }

    func noteDidEdit(range: NSRange, delta: Int) {
        // Highlighter needs ordered incremental edits immediately (tree-sitter).
        highlighter?.documentDidEdit(range: range, delta: delta)
        // Fold + annotations depend on a consistent line index. Defer until the
        // layout transaction ends (or flush now if we are not in one).
        pendingPostEditSideEffects.append((range, delta))
        if !layout.isInTransaction {
            flushPostEditSideEffects()
        }
    }

    /// Applies deferred fold/annotation updates after the line index has absorbed edits.
    func flushPostEditSideEffects() {
        let batch = pendingPostEditSideEffects
        guard !batch.isEmpty else { return }
        pendingPostEditSideEffects.removeAll(keepingCapacity: true)
        for item in batch {
            noteFoldingEdit(range: item.range, delta: item.delta)
            noteAnnotationEdit(range: item.range, delta: item.delta)
        }
    }

    // MARK: - Coordinators / lifecycle observers

    public func setCoordinators(_ coordinators: [any EditorCoordinator]) {
        for box in weakCoordinators {
            box.value?.destroy()
        }
        weakCoordinators = coordinators.map { WeakCoordinator($0) }
        self.coordinators = coordinators
        for coordinator in coordinators {
            coordinator.prepare(controller: self)
        }
    }

    /// Registers versioned lifecycle observers (does not retain them strongly beyond the array).
    public func setLifecycleObservers(_ observers: [any EditorLifecycleObserver]) {
        let context = EditorContext(documentVersion: document.version)
        for box in weakLifecycleObservers {
            box.value?.editorDidDetach(context)
        }
        weakLifecycleObservers = observers.map { WeakLifecycleObserver($0) }
        lifecycleObservers = observers
        let attach = EditorContext(documentVersion: document.version)
        for observer in observers {
            observer.editorDidAttach(attach)
        }
    }

    var liveLifecycleObservers: [any EditorLifecycleObserver] {
        weakLifecycleObservers.compactMap(\.value)
    }

    public func notifyDidAppear() {
        for coordinator in liveCoordinators {
            coordinator.controllerDidAppear(controller: self)
        }
    }

    public func notifyDidDisappear() {
        // Cancel highlight work tied to visibility; remote observation is owned by attach lifetime.
        cancelPendingHighlightWork()
        for coordinator in liveCoordinators {
            coordinator.controllerDidDisappear(controller: self)
        }
    }

    /// Cancels revision-stamped highlight / provider work (safe to call repeatedly).
    public func cancelPendingHighlightWork() {
        highlighter?.cancelPendingWork()
    }

    /// Accessibility label for platform hosts.
    public var accessibilityLabelText: String {
        EditorAccessibility.label(
            languageID: languageID,
            isEditable: configuration.behavior.isEditable,
            isDirty: textDocument.isDirty
        )
    }

    /// Virtualized accessibility value for platform hosts (UI-007 / UI-N10): selection + visible lines.
    public var accessibilityValueText: String {
        let visible = layout.latestVisibleUTF16Range
        return EditorAccessibility.virtualizedValueText(
            fullText: text,
            selectedRange: selectedRange,
            visibleUTF16Range: visible.length > 0 ? visible : nil
        )
    }

    /// Semantic line/column/selection announcement (UI-N10).
    public var accessibilitySemanticSummary: EditorAccessibility.SemanticSummary {
        EditorAccessibility.semanticSummary(
            fullText: text,
            selectedRange: selectedRange,
            multiCursorCount: selectedRanges.count,
            languageID: languageID,
            isEditable: configuration.behavior.isEditable,
            isDirty: textDocument.isDirty,
            largeFileModeActive: largeFileMode.isActive
        )
    }

    /// Host-supplied breakpoint UTF-16 offsets for accessibility rotors (UI-N10).
    public private(set) var accessibilityBreakpointOffsets: [Int] = []

    /// Host-supplied document symbol count for accessibility rotors (UI-N10).
    public private(set) var accessibilitySymbolCount: Int = 0

    /// Publish breakpoint markers for VoiceOver / rotor navigation (UI-N10).
    public func setAccessibilityBreakpoints(_ offsets: [Int]) {
        accessibilityBreakpointOffsets = offsets.filter { $0 >= 0 }
        onNeedsDisplay?()
    }

    /// Publish document-symbol count for accessibility rotors (UI-N10).
    public func setAccessibilitySymbolCount(_ count: Int) {
        accessibilitySymbolCount = max(0, count)
    }

    /// Rotor surfaces derived from live editor state (UI-N10).
    public var accessibilityRotorItems: [EditorAccessibility.RotorItem] {
        let foldCount = largeFileMode.foldingEnabled ? foldModel.foldCache.allFolds.count : 0
        let diagnosticsCount = largeFileMode.diagnosticsEnabled ? annotations.count : 0
        return EditorAccessibility.rotorItems(
            diagnosticsCount: diagnosticsCount,
            foldCount: foldCount,
            changeCount: textDocument.isDirty ? 1 : 0,
            breakpointCount: accessibilityBreakpointOffsets.count,
            symbolCount: accessibilitySymbolCount,
            searchMatchCount: findSession.matches.count
        )
    }

    /// Platform hosts build custom rotors from this catalog (UI-N10).
    public var accessibilityCustomRotorDescriptors: [EditorAccessibility.RotorItem] {
        accessibilityRotorItems
    }

    private var liveCoordinators: [any EditorCoordinator] {
        weakCoordinators.compactMap(\.value)
    }

    // MARK: - Cursor / state helpers

    public var cursorPositions: [CursorPosition] {
        selection.selectedRanges.map { CursorPosition.from(range: $0, lineIndex: layout.lineIndex) }
    }

    /// Line indices that contain any caret or selection.
    public var selectedLineIndices: Set<Int> {
        var indices = Set<Int>()
        for range in selection.selectedRanges {
            guard let start = layout.lineIndex.line(atUTF16Offset: range.location) else { continue }
            indices.insert(start.index)
            if range.length > 0 {
                let endOffset = range.location + range.length - 1
                if let end = layout.lineIndex.line(atUTF16Offset: endOffset) {
                    for line in start.index...end.index {
                        indices.insert(line)
                    }
                }
            }
        }
        return indices
    }

    public func makeGutterModel() -> GutterModel {
        let ribbon = configuration.peripherals.showFoldingRibbon ? FoldRibbonMetrics.width : 0
        return GutterModel(
            lineCount: max(1, layout.lineIndex.count),
            font: configuration.font,
            foldingRibbonWidth: ribbon
        )
    }

    // MARK: - Editing

    /// Active IME composition (UI-001/UI-002/UI-N06). When active, platform `setMarkedText` paths
    /// must use ``applyMarkedText`` so undo/LSP are not spammed per composition update.
    public private(set) var markedTextSession: MarkedTextSession = .inactive

    /// True while IME composition is active.
    public var isComposingMarkedText: Bool { markedTextSession.isActive }

    /// Centralized input/action diagnostics — never swallow with `try?` on input paths (UI-N07).
    public let diagnosticChannel = EditorDiagnosticChannel()

    /// Explicit base writing direction overrides (UI-N04).
    public var writingDirectionModel = WritingDirectionModel()

    /// Large-file policy thresholds (UI-N09). Changing policy re-evaluates mode immediately.
    public var largeFilePolicy: LargeFilePolicy = .default {
        didSet {
            guard largeFilePolicy != oldValue else { return }
            refreshLargeFileMode()
        }
    }

    /// Current large-file mode (explicit limitations; never silent) (UI-N09).
    public private(set) var largeFileMode: LargeFileMode = .inactive

    /// Peripherals after large-file policy is applied.
    public var effectivePeripherals: EditorConfiguration.Peripherals {
        var p = configuration.peripherals
        if largeFileMode.isActive {
            if !largeFileMode.minimapEnabled { p.showMinimap = false }
            if !largeFileMode.foldingEnabled { p.showFoldingRibbon = false }
        }
        return p
    }

    /// True when syntax highlighting is allowed under the current large-file policy (UI-N09).
    public var isSyntaxHighlightingEnabled: Bool {
        largeFileMode.syntaxHighlightingEnabled
    }

    /// True when diagnostics annotations are accepted under large-file policy (UI-N09).
    public var isDiagnosticsEnabled: Bool {
        largeFileMode.diagnosticsEnabled
    }

    /// True when folding work is allowed under large-file policy (UI-N09).
    public var isFoldingEnabled: Bool {
        largeFileMode.foldingEnabled
    }

    /// True when semantic-token providers may run (UI-N09).
    public var isSemanticTokensEnabled: Bool {
        largeFileMode.semanticTokensEnabled
    }

    /// Recompute large-file mode from document size and **enforce** policy (UI-N09).
    public func refreshLargeFileMode() {
        let utf16 = document.length
        // Ensure line index exists for non-empty docs.
        if layout.lineIndex.count == 0, utf16 > 0 {
            layout.invalidateAll()
        }
        let lineCount = max(layout.lineIndex.count, text.components(separatedBy: .newlines).count)
        let previous = largeFileMode
        largeFileMode = LargeFileMode.evaluate(
            utf16Length: utf16,
            lineCount: lineCount,
            policy: largeFilePolicy
        )
        // Preserve memory-pressure escalation if already active.
        if previous.enteredViaMemoryPressure {
            largeFileMode = largeFileMode.applyingMemoryPressure(true, policy: largeFilePolicy)
        }
        applyLargeFileModeEffects(previousActive: previous.isActive)
    }

    /// Apply system memory-pressure escalation (UI-N09).
    public func applyMemoryPressure(_ pressure: Bool) {
        let previous = largeFileMode
        largeFileMode = largeFileMode.applyingMemoryPressure(pressure, policy: largeFilePolicy)
        applyLargeFileModeEffects(previousActive: previous.isActive)
    }

    /// Enforce large-file limitations on highlighter, undo, folds, diagnostics (UI-N09).
    func applyLargeFileModeEffects(previousActive: Bool) {
        // Syntax highlighting: suspend provider work when disabled (viewport-only when active is still off).
        highlighter?.isSuspended = !largeFileMode.syntaxHighlightingEnabled
        if !largeFileMode.syntaxHighlightingEnabled {
            highlighter?.cancelPendingWork()
        }

        // Bounded undo: retain only the newest N groups.
        if largeFileMode.boundedUndo {
            undoCoordinator.maxGroups = largeFileMode.maxUndoGroups
            undoCoordinator.trimToMaxGroups()
        } else {
            undoCoordinator.maxGroups = nil
        }

        // Folding: drop collapsed state / skip rebuilds when disabled.
        if !largeFileMode.foldingEnabled {
            for fold in foldModel.collapsedFolds {
                _foldModel.setCollapsed(false, forFold: fold)
            }
        }

        // Diagnostics: strip annotations when disabled.
        if !largeFileMode.diagnosticsEnabled, !_annotationStore.items.isEmpty {
            clearAnnotations()
        }

        // Semantic tokens: drop SemanticTokensHighlightAdapter when disabled.
        if !largeFileMode.semanticTokensEnabled {
            let filtered = highlightProviders.filter { !($0 is SemanticTokensHighlightAdapter) }
            if filtered.count != highlightProviders.count {
                setHighlightProviders(filtered)
            }
        }

        if largeFileMode.isActive, !previousActive || largeFileMode.enteredViaMemoryPressure {
            diagnosticChannel.report(
                EditorDiagnostic(
                    domain: .largeFile,
                    severity: .info,
                    message: largeFileMode.limitationsDescription
                )
            )
        }
        onNeedsDisplay?()
    }

    public func replaceCharacters(in range: NSRange, with string: String) {
        replaceCharacters(in: range, with: string, registerUndo: true)
    }

    /// Replace with optional undo registration (marked-text provisional uses `false`).
    public func replaceCharacters(in range: NSRange, with string: String, registerUndo: Bool) {
        guard configuration.isEditable else { return }
        let origin: EditOrigin = registerUndo ? .programmatic : .programmatic
        let transaction = EditTransaction.single(range: range, replacement: string, origin: origin)
        _ = applyEditTransaction(transaction, registerUndo: registerUndo) { _ in
            self.selection.setInsertionPoint(range.location + string.utf16.count)
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        publishSelectionChange()
    }

    /// Begin IME composition, capturing pre-composition document snapshot for cancel (UI-N06).
    public func beginMarkedTextComposition(replacing replaceRange: NSRange) {
        markedTextSession.beginComposition(
            documentSnapshot: text,
            replaceRange: replaceRange
        )
    }

    /// Apply or update marked (composition) text without undo registration (UI-002 / UI-N06).
    public func applyMarkedText(
        _ text: String,
        selectedRangeInMarked: NSRange,
        replaceRange: NSRange?
    ) {
        guard configuration.isEditable else { return }
        let baseRange: NSRange
        if let replaceRange, replaceRange.location != NSNotFound {
            baseRange = replaceRange
        } else if markedTextSession.isActive {
            baseRange = markedTextSession.range
        } else {
            let sel = selectedRange
            baseRange = sel
        }
        if !markedTextSession.isActive || markedTextSession.preCompositionDocumentSnapshot == nil {
            markedTextSession.beginComposition(documentSnapshot: self.text, replaceRange: baseRange)
        }
        replaceCharacters(in: baseRange, with: text, registerUndo: false)
        markedTextSession.setMarked(
            text: text,
            selectedRangeInMarked: selectedRangeInMarked,
            documentReplaceRange: NSRange(location: baseRange.location, length: (text as NSString).length)
        )
        if let abs = markedTextSession.absoluteSelectedRange {
            selection.setSelectedRange(abs)
        }
        publishSelectionChange()
    }

    /// Clear marked state after IME commits (`unmarkText`). Does not re-apply text.
    public func clearMarkedTextSession() {
        markedTextSession.clear()
    }

    /// Cancel composition and restore the pre-composition document snapshot (UI-N06).
    public func cancelMarkedTextComposition() {
        guard markedTextSession.isActive || markedTextSession.preCompositionDocumentSnapshot != nil else {
            markedTextSession.clear()
            return
        }
        if let snapshot = markedTextSession.preCompositionDocumentSnapshot {
            let restoreRange = NSRange(location: 0, length: document.length)
            replaceCharacters(in: restoreRange, with: snapshot, registerUndo: false)
            if let r = markedTextSession.preCompositionReplaceRange {
                selection.setSelectedRange(NSRange(location: r.location, length: 0))
            }
        }
        markedTextSession.clear()
        publishSelectionChange()
    }

    /// Commit composition: register one undo unit for the final composition (UI-N06).
    public func commitMarkedTextComposition() {
        commitMarkedTextAsNormalEdit()
    }

    /// Finalize composition: document already holds provisional text (no per-keystroke undo).
    /// Restores the pre-composition snapshot and re-applies the committed string as **one**
    /// undoable edit so Undo reverses the entire composition (UI-N06).
    public func commitMarkedTextAsNormalEdit() {
        let snapshot = markedTextSession.preCompositionDocumentSnapshot
        let replace = markedTextSession.preCompositionReplaceRange
        let committed = markedTextSession.text
        markedTextSession.clear()

        if let snapshot, let replace {
            let full = NSRange(location: 0, length: document.length)
            replaceCharacters(in: full, with: snapshot, registerUndo: false)
            let loc = min(max(0, replace.location), (snapshot as NSString).length)
            let maxLen = (snapshot as NSString).length - loc
            let len = min(max(0, replace.length), maxLen)
            replaceCharacters(
                in: NSRange(location: loc, length: len),
                with: committed,
                registerUndo: true
            )
        } else {
            textDocument.undo.endGrouping()
        }
    }

    public func insertText(_ string: String) {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        guard !ranges.isEmpty else { return }

        // Single-char auto-pair / skip-over when all carets are empty.
        if string.count == 1, ranges.allSatisfy({ $0.length == 0 }) {
            if applyAutoPairOrSkip(typed: string, carets: ranges) {
                return
            }
        }

        let ordered = ranges.sorted { $0.location > $1.location }
        let changes = ordered.map { TextChange(range: $0, replacement: string) }
        let transaction = EditTransaction(changes: changes, origin: .typing)
        _ = applyEditTransaction(transaction) { applied in
            var carets: [Int] = []
            for edit in applied.textEdits {
                carets.append(
                    MultiRangeEdit.caretAfterReplace(
                        range: edit.range,
                        replacementUTF16Count: string.utf16.count
                    )
                )
            }
            self.selection.setSelectedRanges(
                carets.reversed().map { NSRange(location: $0, length: 0) }
            )
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        publishSelectionChange()
        noteTextInsertedForCompletions(string)
    }

    // MARK: - Formation / structure

    public func insertTab() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        let hasSelection = ranges.contains { $0.length > 0 }
        if hasSelection {
            indentSelection()
            return
        }
        insertText(TextFilters.expandTab(indent: configuration.behavior.indentOption))
    }

    public func insertBacktab() {
        guard configuration.isEditable else { return }
        outdentSelection()
    }

    public func insertNewline() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        guard !ranges.isEmpty else { return }

        // High → low so earlier carets stay valid; precompute payloads against current text.
        var changes: [TextChange] = []
        var caretByLocation: [(location: Int, caret: Int)] = []
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let insertion = newlineInsertion(at: range.location, replacing: range)
            changes.append(TextChange(range: range, replacement: insertion.payload))
            caretByLocation.append((range.location, range.location + insertion.caretOffsetInPayload))
        }

        let transaction = EditTransaction(changes: changes, origin: .typing)
        _ = applyEditTransaction(transaction) { _ in
            self.selection.setSelectedRanges(
                caretByLocation.map(\.caret).sorted().map { NSRange(location: $0, length: 0) }
            )
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        publishSelectionChange()
    }

    public func indentSelection() {
        applyStructureReplacements(
            StructureCommands.indentLines(
                selections: selection.selectedRanges,
                document: document.fullString,
                indent: configuration.behavior.indentOption
            )
        )
    }

    public func outdentSelection() {
        applyStructureReplacements(
            StructureCommands.outdentLines(
                selections: selection.selectedRanges,
                document: document.fullString,
                indent: configuration.behavior.indentOption
            )
        )
    }

    public func moveSelectedLines(up: Bool) {
        guard configuration.isEditable else { return }
        guard
            let plan = StructureCommands.moveLines(
                selections: selection.selectedRanges,
                document: document.fullString,
                up: up
            )
        else { return }
        applyStructureReplacements(plan.replacements, forceSelection: plan.newSelection)
    }

    public func toggleLineComment() {
        let marker = language?.lineComment ?? ""
        guard !marker.isEmpty else { return }
        applyStructureReplacements(
            StructureCommands.toggleLineComment(
                selections: selection.selectedRanges,
                document: document.fullString,
                lineComment: marker
            )
        )
    }

    public func toggleBlockComment() {
        guard configuration.isEditable else { return }
        let open = language?.rangeComment.0 ?? ""
        let close = language?.rangeComment.1 ?? ""
        guard !open.isEmpty, !close.isEmpty else { return }
        let primary = selection.selectedRange
        guard primary.length > 0,
            let rep = StructureCommands.toggleBlockComment(
                selection: primary,
                document: document.fullString,
                open: open,
                close: close
            )
        else { return }
        applyStructureReplacements([rep])
    }

    /// Applies auto-pair or skip-over for single-character typing at empty carets.
    /// - Returns: `true` if the insert was fully handled.
    private func applyAutoPairOrSkip(typed: String, carets: [NSRange]) -> Bool {
        let ns = document.fullString as NSString
        var anyPair = false
        var anySkip = false
        var payloads: [(range: NSRange, insert: String, inside: Bool, skip: Bool)] = []

        for caret in carets {
            let next: Character?
            if caret.location < ns.length {
                let s = ns.substring(with: NSRange(location: caret.location, length: 1))
                next = s.first
            } else {
                next = nil
            }
            if let result = TextFilters.autoPair(inserted: typed, nextCharacter: next) {
                anyPair = anyPair || result.placeCaretInside
                anySkip = anySkip || result.skipOver
                payloads.append((caret, result.insert, result.placeCaretInside, result.skipOver))
            } else {
                return false
            }
        }
        // Only handle when every caret got a pair/skip result of the same kind.
        let allSkip = payloads.allSatisfy(\.skip)
        let allPair = payloads.allSatisfy { $0.inside && !$0.skip }
        guard allSkip || allPair else { return false }

        var changes: [TextChange] = []
        var newCarets: [Int] = []
        for item in payloads.sorted(by: { $0.range.location > $1.range.location }) {
            if item.skip {
                newCarets.append(item.range.location + 1)
                continue
            }
            changes.append(TextChange(range: item.range, replacement: item.insert))
            let inside = item.inside ? 1 : item.insert.utf16.count
            newCarets.append(item.range.location + inside)
        }

        if !changes.isEmpty {
            let transaction = EditTransaction(changes: changes, origin: .formation)
            _ = applyEditTransaction(transaction) { _ in
                self.selection.setSelectedRanges(
                    newCarets.sorted().map { NSRange(location: $0, length: 0) }
                )
                self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
            }
        } else {
            selection.setSelectedRanges(newCarets.sorted().map { NSRange(location: $0, length: 0) })
            updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        }
        publishSelectionChange()
        return true
    }

    private func newlineInsertion(at utf16Offset: Int, replacing range: NSRange) -> TextFilters.NewlineInsertion {
        let ns = document.fullString as NSString
        let length = ns.length
        let loc = min(max(0, utf16Offset), length)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: min(loc, max(0, length - 1)), length: 0)
        )
        // Text on this line before the caret (ignore selection body).
        let prefixLen = max(0, min(loc, contentsEnd) - lineStart)
        let beforeCaret =
            prefixLen > 0
            ? ns.substring(with: NSRange(location: lineStart, length: prefixLen))
            : ""
        // Character immediately after the selection/caret (drives brace-split Enter).
        let afterLoc = range.location + range.length
        let next: Character?
        if afterLoc < length {
            next = ns.substring(with: NSRange(location: afterLoc, length: 1)).first
        } else {
            next = nil
        }
        return TextFilters.newlineInsertion(
            lineTextBeforeCaret: beforeCaret,
            nextCharacter: next,
            indent: configuration.behavior.indentOption
        )
    }

    /// Applies precomputed replacements (must already be high→low). Adjusts selection to carets after each edit.
    private func applyStructureReplacements(
        _ replacements: [TextReplacement],
        forceSelection: NSRange? = nil
    ) {
        guard configuration.isEditable, !replacements.isEmpty else { return }
        let ordered = replacements.sorted { $0.range.location > $1.range.location }
        let changes = ordered.map { TextChange(range: $0.range, replacement: $0.string) }
        let transaction = EditTransaction(changes: changes, origin: .structure)
        _ = applyEditTransaction(transaction) { applied in
            if let forceSelection {
                self.selection.setSelectedRange(forceSelection)
            } else {
                var carets = self.selection.selectedRanges
                for edit in applied.textEdits {
                    carets = MultiRangeEdit.remap(
                        ranges: carets,
                        editLocation: edit.range.location,
                        delta: edit.mutation.delta
                    )
                }
                self.selection.setSelectedRanges(carets)
            }
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        publishSelectionChange()
    }

    public func deleteBackward() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        let working = ranges.sorted { $0.location > $1.location }
        var carets: [Int] = []
        var changes: [TextChange] = []
        // High→low keeps lower indices stable; `full` tracks content for indent-aware deletes.
        var full = document.fullString
        for range in working {
            let deleteRange: NSRange
            if range.length > 0 {
                deleteRange = selectionExpandedForCollapsedFolds(range)
            } else if selectedFoldPlaceholderID != nil,
                let fold = foldModel.collapsedFolds.first(where: { $0.id == selectedFoldPlaceholderID })
            {
                deleteRange = fold.nsRange
                selectedFoldPlaceholderID = nil
            } else if let planned = TextFilters.deleteBackwardRange(
                caret: range.location,
                in: full,
                indent: configuration.behavior.indentOption
            ) {
                // TextFilters uses `rangeOfComposedCharacterSequences` (grapheme-safe).
                deleteRange = selectionExpandedForCollapsedFolds(planned)
            } else if range.location > 0 {
                // Fallback: delete one composed character ending at caret (UI-001 / §11.4).
                let ns = full as NSString
                let composed = ns.rangeOfComposedCharacterSequences(
                    for: NSRange(location: range.location - 1, length: 1)
                )
                deleteRange = selectionExpandedForCollapsedFolds(composed)
            } else {
                carets.append(0)
                continue
            }
            expandCollapsedFoldsIntersecting(deleteRange)
            changes.append(TextChange(range: deleteRange, replacement: ""))
            carets.append(deleteRange.location)
            let ns = full as NSString
            let start = min(max(0, deleteRange.location), ns.length)
            let end = min(ns.length, start + max(0, deleteRange.length))
            full = ns.substring(to: start) + ns.substring(from: end)
        }
        guard !changes.isEmpty else {
            selection.setSelectedRanges(carets.sorted().map { NSRange(location: $0, length: 0) })
            publishSelectionChange()
            return
        }
        let transaction = EditTransaction(changes: changes, origin: .typing)
        _ = applyEditTransaction(transaction) { _ in
            self.selection.setSelectedRanges(
                carets.sorted().map { NSRange(location: $0, length: 0) }
            )
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        publishSelectionChange()
    }

    public func deleteForward() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        var carets: [Int] = []
        var changes: [TextChange] = []
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let deleteRange: NSRange
            if range.length > 0 {
                deleteRange = selectionExpandedForCollapsedFolds(range)
            } else if selectedFoldPlaceholderID != nil,
                let fold = foldModel.collapsedFolds.first(where: { $0.id == selectedFoldPlaceholderID })
            {
                deleteRange = fold.nsRange
                selectedFoldPlaceholderID = nil
            } else if range.location < document.length {
                let one = NSRange(location: range.location, length: 1)
                deleteRange = selectionExpandedForCollapsedFolds(one)
            } else {
                carets.append(range.location)
                continue
            }
            expandCollapsedFoldsIntersecting(deleteRange)
            changes.append(TextChange(range: deleteRange, replacement: ""))
            carets.append(deleteRange.location)
        }
        guard !changes.isEmpty else {
            selection.setSelectedRanges(carets.reversed().map { NSRange(location: $0, length: 0) })
            publishSelectionChange()
            return
        }
        let transaction = EditTransaction(changes: changes, origin: .typing)
        _ = applyEditTransaction(transaction) { _ in
            self.selection.setSelectedRanges(
                carets.reversed().map { NSRange(location: $0, length: 0) }
            )
        }
        publishSelectionChange()
    }

    public func undo() {
        // Document-scoped undo emits didApply; this controller applies locally via funnel
        // only when it owns the undo call — TextDocument.undo applies content; we mirror.
        let before = textDocument.version
        do {
            try textDocument.performUndo()
        } catch {
            // Failed undo leaves stacks unchanged; surface nothing at the UI binding layer.
            publishSelectionChange()
            return
        }
        if textDocument.version > before {
            if let id = textDocument.lastAppliedTransactionID {
                lastLocalTransactionID = id
            }
            if usesPresentationMirror {
                document.setFullText(textDocument.text)
            }
            layout.invalidateAll()
            highlighter?.documentDidReplaceAll()
            selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
            lastSeenDocumentVersion = textDocument.version
            publishTextChange()
        }
        publishSelectionChange()
    }

    public func redo() {
        let before = textDocument.version
        do {
            try textDocument.performRedo()
        } catch {
            publishSelectionChange()
            return
        }
        if textDocument.version > before {
            if usesPresentationMirror {
                document.setFullText(textDocument.text)
            }
            if let id = textDocument.lastAppliedTransactionID {
                lastLocalTransactionID = id
            }
            layout.invalidateAll()
            highlighter?.documentDidReplaceAll()
            selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
            lastSeenDocumentVersion = textDocument.version
            publishTextChange()
        }
        publishSelectionChange()
    }

    // MARK: - Selection

    public func setSelectedRange(_ range: NSRange) {
        selection.setSelectedRange(range)
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        publishSelectionChange()
    }

    public func setSelectedRanges(_ ranges: [NSRange]) {
        selection.setSelectedRanges(ranges)
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        publishSelectionChange()
    }

    /// Selects the word (identifier-style) containing `offset`, used for double-click.
    public func selectWord(atUTF16Offset offset: Int) {
        let range = WordSelection.range(atUTF16Offset: offset, in: document.fullString)
        setSelectedRange(range)
    }

    public func addCursor(at offset: Int) {
        selection.addSelection(NSRange(location: offset, length: 0))
        publishSelectionChange()
    }

    public func collapseCursors() {
        selection.collapseToPrimary()
        publishSelectionChange()
    }

    public func move(
        direction: NavigationDirection,
        granularity: NavigationGranularity = .character,
        extending: Bool = false,
        containerWidth: CGFloat
    ) {
        // Vertical character moves use CaretNavigationEngine + layout snapshot (UI-N01).
        if granularity == .character, direction == .up || direction == .down {
            let visual: VisualDirection = direction == .up ? .up : .down
            let width = containerWidth > 0 ? containerWidth : max(contentSize.width, 1)
            _ = layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: width, height: max(layout.contentSize.height, 1)),
                containerWidth: width
            )
            var nextRanges: [NSRange] = []
            var preferredX: CGFloat?
            for sel in selection.selections {
                let head: Int
                if extending {
                    head = sel.end
                } else if direction == .up {
                    head = sel.range.location
                } else {
                    head = sel.end
                }
                let moved = visualCaretMove(
                    from: head,
                    direction: visual,
                    preferredX: sel.preferredX,
                    containerWidth: width
                )
                if preferredX == nil { preferredX = moved.preferredX }
                if extending {
                    let anchor = sel.range.location
                    let loc = min(anchor, moved.position.utf16Offset)
                    let len = abs(anchor - moved.position.utf16Offset)
                    nextRanges.append(NSRange(location: loc, length: len))
                } else {
                    nextRanges.append(NSRange(location: moved.position.utf16Offset, length: 0))
                }
            }
            if !nextRanges.isEmpty {
                selection.setSelectedRanges(nextRanges, preferredX: preferredX)
            }
            updateScrollTarget(containerWidth: width)
            publishSelectionChange()
            return
        }
        selection.move(
            direction: direction,
            granularity: granularity,
            extending: extending,
            containerWidth: containerWidth
        )
        updateScrollTarget(containerWidth: containerWidth)
        publishSelectionChange()
    }

    /// Platform-neutral visual caret step used by AppKit/UIKit hosts (UI-N01).
    public func visualCaretMove(
        from utf16Offset: Int,
        direction: VisualDirection,
        preferredX: CGFloat?,
        containerWidth: CGFloat
    ) -> CaretMovementResult {
        let width = containerWidth > 0 ? containerWidth : max(contentSize.width, 1)
        let snapshot = layout.makeEditorLayoutSnapshot(containerWidth: width, documentText: text)
        return CaretNavigationEngine.move(
            caret: TextPosition(utf16Offset: utf16Offset),
            direction: direction,
            preferredX: preferredX,
            layout: snapshot
        )
    }

    public func selectAll() {
        selection.selectAll()
        publishSelectionChange()
    }

    public func applyColumnSelection(rect: CGRect, containerWidth: CGFloat) {
        let snapshot = layoutViewport(
            visibleRect: rect.insetBy(dx: -10, dy: -10),
            containerWidth: containerWidth
        )
        let columnFragments = snapshot.fragments.map {
            ColumnSelectionFragment(
                frame: $0.frame,
                documentRange: $0.fragment.documentRange,
                ctLine: $0.fragment.ctLine
            )
        }
        let ranges = ColumnSelectionBuilder.ranges(
            in: rect,
            fragments: columnFragments,
            documentLength: document.length
        )
        selection.mode = .column
        setSelectedRanges(ranges)
    }

    // MARK: - Attachments

    public func addAttachment(_ attachment: any TextAttachment, range: NSRange) {
        layout.attachments.add(attachment, range: range)
        layout.invalidateTypeset(in: range)
    }

    // MARK: - Layout

    public func layoutViewport(visibleRect: CGRect, containerWidth: CGFloat) -> LayoutSnapshot {
        let snapshot = layout.layoutViewport(visibleRect: visibleRect, containerWidth: containerWidth)
        latestSnapshot = snapshot
        contentSize = snapshot.contentSize
        updateHighlighting(for: snapshot)
        return snapshot
    }

    /// Updates ``contentSize`` / ``latestSnapshot`` from the layout engine without highlight work.
    func syncContentSizeFromLayout() {
        let width = contentSize.width > 0 ? contentSize.width : 400
        let snapshot = layout.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: width, height: max(layout.contentSize.height, 1)),
            containerWidth: width
        )
        latestSnapshot = snapshot
        contentSize = snapshot.contentSize
    }

    public func caretRect(containerWidth: CGFloat) -> CGRect? {
        layout.caretRect(atUTF16Offset: selection.selectedRange.location, containerWidth: containerWidth)
    }

    /// Caret/placement rect for an arbitrary UTF-16 offset (e.g. jump-to-definition anchor).
    public func caretRect(atUTF16Offset offset: Int, containerWidth: CGFloat) -> CGRect? {
        layout.caretRect(atUTF16Offset: offset, containerWidth: containerWidth)
    }

    /// Placement rect for the completion / jump popover (prefers session anchor over selection).
    public func completionAnchorRect(containerWidth: CGFloat) -> CGRect? {
        if let anchor = completionSession.anchorPosition {
            let offset = max(0, min(anchor.range.location, document.length))
            if let rect = layout.caretRect(atUTF16Offset: offset, containerWidth: containerWidth) {
                return rect
            }
        }
        return caretRect(containerWidth: containerWidth)
    }

    public func caretRects(containerWidth: CGFloat) -> [CGRect] {
        selection.selectedRanges.compactMap {
            layout.caretRect(atUTF16Offset: $0.location, containerWidth: containerWidth)
        }
    }

    public func hitTestOffset(at point: CGPoint, containerWidth: CGFloat) -> Int {
        layout.utf16Offset(at: point, containerWidth: containerWidth)
    }

    public func updateScrollTarget(containerWidth: CGFloat) {
        if let caret = caretRect(containerWidth: containerWidth) {
            scrollTarget = caret.insetBy(dx: -20, dy: -40)
        } else {
            scrollTarget = nil
        }
    }

    /// Hosts call this after applying ``scrollTarget`` so later layout/scroll passes
    /// do not keep re-centering on the caret (which freezes free scrolling).
    public func consumeScrollTarget() {
        scrollTarget = nil
    }

    // MARK: - Drag session helpers

    public func text(in ranges: [NSRange]) -> String {
        ranges.sorted { $0.location < $1.location }.compactMap { document.substring(from: $0) }.joined(separator: "\n")
    }

    public func moveText(from ranges: [NSRange], to dropOffset: Int) {
        guard configuration.isEditable else { return }
        let ordered = ranges.sorted { $0.location < $1.location }
        let pieces = ordered.compactMap { document.substring(from: $0) }
        let payload = pieces.joined(separator: "\n")

        // Sequential apply: deletes high→low (pre-edit coords), then insert at post-delete drop.
        let deleteChanges = ordered.reversed().map { TextChange(range: $0, replacement: "") }
        var plannedDrop = dropOffset
        for range in ordered.reversed() {
            if range.location + range.length <= dropOffset {
                plannedDrop -= range.length
            } else if range.location < dropOffset {
                plannedDrop = range.location
            }
        }
        let insertChange = TextChange(
            range: NSRange(location: max(0, plannedDrop), length: 0),
            replacement: payload
        )
        let transaction = EditTransaction(
            changes: deleteChanges + [insertChange],
            origin: .drop
        )
        _ = applyEditTransaction(
            transaction,
            sortHighToLow: false
        ) { applied in
            // Last edit is the insert.
            if let insert = applied.textEdits.last {
                self.selection.setSelectedRange(
                    NSRange(location: insert.range.location, length: payload.utf16.count)
                )
            }
        }
        publishSelectionChange()
    }

    // MARK: - Private

    private func replaceFullText(_ string: String) {
        applyFullTextReplace(string)
    }

    private func applyConfiguration(old: EditorConfiguration?) {
        document.defaultAttributes = configuration.typingAttributes
        layout.wrapLines = configuration.wrapLines
        layout.lineHeightMultiplier = configuration.lineHeightMultiplier
        layout.lineBreakStrategy = configuration.lineBreakStrategy
        layout.updateTypingAttributes(configuration.typingAttributes)
        selection.isEnabled = configuration.isSelectable

        // Gutter + minimap contribute to horizontal content insets.
        let hostWidth = contentSize.width > 0 ? contentSize.width : 800
        let model = makeGutterModel()
        let gutter = configuration.peripherals.showGutter ? model.width : 0
        let mini =
            configuration.peripherals.showMinimap
            ? MinimapGeometry.width(hostWidth: hostWidth)
            : 0
        applyHorizontalInsets(gutterWidth: gutter, minimapWidth: mini)

        if configuration.showInvisibleCharacters {
            if invisibleCharactersDelegate == nil {
                invisibleCharactersDelegate = DefaultInvisibleCharactersDelegate()
            }
        } else if old?.showInvisibleCharacters == true {
            invisibleCharactersDelegate = nil
        }

        if old == nil
            || old?.appearance.font != configuration.appearance.font
            || old?.appearance.theme.text.color != configuration.appearance.theme.text.color
            || old?.appearance.letterSpacing != configuration.appearance.letterSpacing
            || old?.appearance.wrapLines != configuration.appearance.wrapLines
            || old?.appearance.lineHeightMultiple != configuration.appearance.lineHeightMultiple
            || old?.layout.lineBreakStrategy != configuration.layout.lineBreakStrategy
            || old?.peripherals.showGutter != configuration.peripherals.showGutter
            || old?.peripherals.showFoldingRibbon != configuration.peripherals.showFoldingRibbon
            || old?.peripherals.showMinimap != configuration.peripherals.showMinimap
        {
            layout.invalidateAll()
        }

        if old != nil, old?.appearance.theme != configuration.appearance.theme {
            highlighter?.updateHooks(makeHighlightHooks())
            highlighter?.themeDidChange()
        }

        if old?.peripherals.showFoldingRibbon != configuration.peripherals.showFoldingRibbon {
            if configuration.peripherals.showFoldingRibbon {
                rebuildFolds()
            } else {
                // Expand all and clear placeholders when ribbon is turned off.
                for fold in _foldModel.collapsedFolds {
                    _foldModel.setCollapsed(false, forFold: fold)
                }
                layout.attachments.remove { $0.attachment is LineFoldPlaceholder }
                layout.applyCollapsedFoldHeights(collapsedFolds: [], hideCloserLines: false, document: "")
                selectedFoldPlaceholderID = nil
            }
        }

        updateBracketEmphasis()
    }

    func publishTextChange() {
        events.yield(.textDidChange)
        let full = document.fullString
        events.yieldText(full)
        // Gutter width may change with line count digit growth.
        let model = makeGutterModel()
        let newGutter = configuration.peripherals.showGutter ? model.width : 0
        if abs(newGutter - gutterWidth) > 0.5 {
            let hostWidth = contentSize.width > 0 ? contentSize.width : 800
            let mini =
                configuration.peripherals.showMinimap
                ? MinimapGeometry.width(hostWidth: hostWidth)
                : 0
            applyHorizontalInsets(gutterWidth: newGutter, minimapWidth: mini)
            layout.invalidateAll()
        }
        for coordinator in liveCoordinators {
            coordinator.textDidChange(controller: self)
        }
        // Keep host bindings in sync even when focus is in the find panel (not the editor view).
        onTextDidChange?(full)
        updateBracketEmphasis()
        if findSession.isShowing, !findSession.findText.isEmpty, !isApplyingFindReplace {
            recomputeFindMatches(selectCurrent: false, flashCurrent: false)
        }
        syncEditorStateCursors()
        syncEditorStateFind()
    }

    func publishSelectionChange() {
        events.yield(.selectionDidChange)
        let detailed = SelectionChangeEvent(
            nsRanges: selection.selectedRanges,
            version: textDocument.version
        )
        syncSessionFromController()
        events.yield(.selectionDidChangeDetailed(detailed))
        events.yieldSelection(selection.selectedRanges)
        let cursors = cursorPositions
        for coordinator in liveCoordinators {
            coordinator.selectionDidChange(controller: self, cursors: cursors)
        }
        for observer in liveLifecycleObservers {
            observer.editorSelectionDidChange(detailed)
        }
        updateBracketEmphasis()
        syncEditorStateCursors()
        // Keep SwiftUI / host selection bindings in sync (jump panel, find, API).
        onSelectionDidChange?(selection.selectedRange)
        // Jump multi-target popover reuses the completion session — do not treat
        // selection changes as typing-completion filter updates for that mode.
        // Single refilter while the popup is open (covers typing + arrow keys).
        if completionSession.isVisible, !isJumpLinkPopoverVisible {
            noteCursorMovedForCompletions()
        }
    }

    private func syncEditorStateCursors() {
        editorState.cursorPositions = cursorPositions
    }

    /// Updates gutter width storage and horizontal layout insets (gutter leading + minimap trailing).
    func applyHorizontalInsets(gutterWidth: CGFloat, minimapWidth: CGFloat) {
        self.gutterWidth = gutterWidth
        let content = configuration.layout.contentInsets
        layout.edgeInsets = HorizontalEdgeInsets(
            leading: content.leading + gutterWidth,
            trailing: content.trailing + minimapWidth
        )
    }

    func syncEditorStateFind() {
        editorState.findText = findSession.findText
        editorState.replaceText = findSession.replaceText
        editorState.findPanelVisible = findSession.isShowing
    }

    func notifyFindSessionChange() {
        syncEditorStateFind()
        onFindSessionChange?()
        onNeedsDisplay?()
    }

    /// Emphasizes matching brackets around each caret when configured.
    private func updateBracketEmphasis() {
        emphasis.removeAll(in: bracketEmphasisGroup)
        guard let style = configuration.appearance.bracketPairEmphasis else { return }

        let text = document.fullString
        var seen = Set<String>()
        for range in selection.selectedRanges where range.length == 0 {
            guard let match = BracketMatcher.match(aroundUTF16Offset: range.location, in: text) else {
                continue
            }
            let key = "\(match.open.location)-\(match.close.location)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            let emphasisStyle: EmphasisStyle
            let flash: Bool
            switch style {
            case .flash:
                emphasisStyle = .outline
                flash = true
            case .bordered:
                emphasisStyle = .outline
                flash = false
            case .underline:
                emphasisStyle = .underline
                flash = false
            }

            emphasis.add(
                Emphasis(
                    range: match.open,
                    style: emphasisStyle,
                    flash: flash,
                    group: bracketEmphasisGroup
                )
            )
            emphasis.add(
                Emphasis(
                    range: match.close,
                    style: emphasisStyle,
                    flash: flash,
                    group: bracketEmphasisGroup
                )
            )
        }
    }
}
