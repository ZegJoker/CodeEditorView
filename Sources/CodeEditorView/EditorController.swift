import CoreGraphics
import Foundation
import Observation
import TextStory
import CodeEditorLanguages

/// Central editor model: document, layout, multi-range selection, undo, emphasis, and event streams.
@MainActor
@Observable
public final class EditorController {
    public private(set) var document: DocumentStore
    public let layout: LayoutEngine
    public let selection: SelectionEngine
    public let undoCoordinator: UndoCoordinator
    public let events: EditorEventStream
    public let emphasis: EmphasisManager

    public var configuration: EditorConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            applyConfiguration(old: oldValue)
        }
    }

    public var invisibleCharactersDelegate: InvisibleCharactersDelegate? {
        didSet { /* hosts redraw */ }
    }

    /// Two-way UI state (cursors, scroll, find panel fields).
    public var editorState: EditorState = .empty

    /// Width of the line-number gutter (0 when hidden).
    public private(set) var gutterWidth: CGFloat = 0

    /// Coordinators receive lifecycle/edit callbacks (no Combine).
    public private(set) var coordinators: [any EditorCoordinator] = []

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
    private var languageConfigInFlight = false

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

    private var weakCoordinators: [WeakCoordinator] = []
    private let bracketEmphasisGroup = "bracket-pairs"

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

    public init(
        text: String = "",
        configuration: EditorConfiguration = EditorConfiguration(),
        coordinators: [any EditorCoordinator] = [],
        highlightProviders: [any HighlightProviding] = [],
        language: CodeLanguage? = nil,
        languageID: String? = nil
    ) {
        self.configuration = configuration
        let resolvedLanguage = language ?? languageID.flatMap { CodeLanguages.language(id: $0) }
        self.language = resolvedLanguage
        self.languageID = resolvedLanguage?.id.rawValue ?? languageID
        self.document = DocumentStore(string: text, attributes: configuration.typingAttributes)
        self.layout = LayoutEngine()
        self.selection = SelectionEngine()
        self.undoCoordinator = UndoCoordinator()
        self.events = EditorEventStream()
        self.emphasis = EmphasisManager()

        layout.attach(document: document, typingAttributes: configuration.typingAttributes)
        selection.attach(document: document, layout: layout)
        emphasis.onChange = { [weak self] in
            self?.events.yield(.selectionDidChange)
        }
        if configuration.showInvisibleCharacters {
            invisibleCharactersDelegate = DefaultInvisibleCharactersDelegate()
        }
        applyConfiguration(old: nil)
        setCoordinators(coordinators)

        highlighter = Highlighter(hooks: makeHighlightHooks())
        highlighter.setLanguageID(self.languageID)

        if !highlightProviders.isEmpty {
            setHighlightProviders(highlightProviders)
        } else if let resolvedLanguage, let provider = TreeSitterHighlightProvider.make(for: resolvedLanguage) {
            setHighlightProviders([provider])
        }
    }

    // MARK: - Highlighting

    public func setHighlightProviders(_ providers: [any HighlightProviding]) {
        highlightProviders = providers
        highlighter.updateHooks(makeHighlightHooks())
        highlighter.setProviders(providers)
    }

    /// Call from hosts when the visible document UTF-16 range changes.
    public func setVisibleUTF16RangeForHighlighting(_ range: NSRange) {
        highlighter.updateHooks(makeHighlightHooks())
        highlighter.setVisibleUTF16Range(range)
    }

    /// Convenience: map a layout snapshot’s fragments to a UTF-16 highlight window.
    public func updateHighlighting(for snapshot: LayoutSnapshot) {
        guard !snapshot.fragments.isEmpty else {
            setVisibleUTF16RangeForHighlighting(NSRange(location: 0, length: document.length))
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

    private func makeHighlightHooks() -> Highlighter.DocumentHooks {
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
            }
        )
    }

    private func noteWillEdit(_ range: NSRange) {
        highlighter?.willApplyEdit(range: range)
    }

    private func noteDidEdit(range: NSRange, delta: Int) {
        highlighter?.documentDidEdit(range: range, delta: delta)
    }

    // MARK: - Coordinators

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

    public func notifyDidAppear() {
        for coordinator in liveCoordinators {
            coordinator.controllerDidAppear(controller: self)
        }
    }

    public func notifyDidDisappear() {
        for coordinator in liveCoordinators {
            coordinator.controllerDidDisappear(controller: self)
        }
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
        GutterModel(
            lineCount: max(1, layout.lineIndex.count),
            font: configuration.font
        )
    }

    // MARK: - Editing

    public func replaceCharacters(in range: NSRange, with string: String) {
        guard configuration.isEditable else { return }
        events.yield(.willChangeText)
        noteWillEdit(range)
        layout.beginTransaction()
        let edit = document.replaceCharacters(in: range, with: string)
        undoCoordinator.register(edit: edit)
        layout.documentDidReplace(range: range, delta: edit.mutation.delta)
        layout.endTransaction()
        noteDidEdit(range: range, delta: edit.mutation.delta)
        selection.setInsertionPoint(range.location + string.utf16.count)
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        publishTextChange()
        publishSelectionChange()
    }

    public func insertText(_ string: String) {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        guard !ranges.isEmpty else { return }

        events.yield(.willChangeText)
        for range in ranges { noteWillEdit(range) }
        undoCoordinator.beginGrouping()
        layout.beginTransaction()
        let edits = selection.replaceAllSelections(with: string)
        for edit in edits {
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
            noteDidEdit(range: edit.range, delta: edit.mutation.delta)
        }
        layout.endTransaction()
        undoCoordinator.endGrouping()
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        publishTextChange()
        publishSelectionChange()
    }

    public func deleteBackward() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        events.yield(.willChangeText)
        undoCoordinator.beginGrouping()
        layout.beginTransaction()

        let working = ranges.sorted { $0.location > $1.location }
        var carets: [Int] = []
        for range in working {
            let deleteRange: NSRange
            if range.length > 0 {
                deleteRange = range
            } else if range.location > 0 {
                deleteRange = NSRange(location: range.location - 1, length: 1)
            } else {
                carets.append(0)
                continue
            }
            noteWillEdit(deleteRange)
            let edit = document.replaceCharacters(in: deleteRange, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: deleteRange, delta: edit.mutation.delta)
            noteDidEdit(range: deleteRange, delta: edit.mutation.delta)
            carets.append(deleteRange.location)
        }
        layout.endTransaction()
        undoCoordinator.endGrouping()
        selection.setSelectedRanges(carets.reversed().map { NSRange(location: $0, length: 0) })
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        publishTextChange()
        publishSelectionChange()
    }

    public func deleteForward() {
        guard configuration.isEditable else { return }
        let ranges = selection.selectedRanges
        events.yield(.willChangeText)
        undoCoordinator.beginGrouping()
        layout.beginTransaction()

        var carets: [Int] = []
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let deleteRange: NSRange
            if range.length > 0 {
                deleteRange = range
            } else if range.location < document.length {
                deleteRange = NSRange(location: range.location, length: 1)
            } else {
                carets.append(range.location)
                continue
            }
            noteWillEdit(deleteRange)
            let edit = document.replaceCharacters(in: deleteRange, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: deleteRange, delta: edit.mutation.delta)
            noteDidEdit(range: deleteRange, delta: edit.mutation.delta)
            carets.append(deleteRange.location)
        }
        layout.endTransaction()
        undoCoordinator.endGrouping()
        selection.setSelectedRanges(carets.reversed().map { NSRange(location: $0, length: 0) })
        publishTextChange()
        publishSelectionChange()
    }

    public func undo() {
        undoCoordinator.undo { [weak self] edit in
            guard let self else { return }
            self.events.yield(.willChangeText)
            self.noteWillEdit(edit.inverse.range)
            self.layout.beginTransaction()
            self.document.applyMutation(edit.inverse)
            self.layout.documentDidReplace(range: edit.inverse.range, delta: edit.inverse.delta)
            self.layout.endTransaction()
            self.noteDidEdit(range: edit.inverse.range, delta: edit.inverse.delta)
            self.selection.setInsertionPoint(edit.inverse.range.location + edit.inverse.string.utf16.count)
        }
        publishTextChange()
        publishSelectionChange()
    }

    public func redo() {
        undoCoordinator.redo { [weak self] edit in
            guard let self else { return }
            self.events.yield(.willChangeText)
            self.noteWillEdit(edit.mutation.range)
            self.layout.beginTransaction()
            self.document.applyMutation(edit.mutation)
            self.layout.documentDidReplace(range: edit.mutation.range, delta: edit.mutation.delta)
            self.layout.endTransaction()
            self.noteDidEdit(range: edit.mutation.range, delta: edit.mutation.delta)
            self.selection.setInsertionPoint(edit.mutation.range.location + edit.mutation.string.utf16.count)
        }
        publishTextChange()
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
        selection.move(
            direction: direction,
            granularity: granularity,
            extending: extending,
            containerWidth: containerWidth
        )
        updateScrollTarget(containerWidth: containerWidth)
        publishSelectionChange()
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
        let ranges = ColumnSelectionBuilder.ranges(
            in: rect,
            fragments: snapshot.fragments,
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

    public func caretRect(containerWidth: CGFloat) -> CGRect? {
        layout.caretRect(atUTF16Offset: selection.selectedRange.location, containerWidth: containerWidth)
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

    // MARK: - Drag session helpers

    public func text(in ranges: [NSRange]) -> String {
        ranges.sorted { $0.location < $1.location }.compactMap { document.substring(from: $0) }.joined(separator: "\n")
    }

    public func moveText(from ranges: [NSRange], to dropOffset: Int) {
        guard configuration.isEditable else { return }
        let ordered = ranges.sorted { $0.location < $1.location }
        let pieces = ordered.compactMap { document.substring(from: $0) }
        let payload = pieces.joined(separator: "\n")
        events.yield(.willChangeText)
        undoCoordinator.beginGrouping()
        layout.beginTransaction()

        // Delete high → low
        var adjustedDrop = dropOffset
        for range in ordered.reversed() {
            noteWillEdit(range)
            let edit = document.replaceCharacters(in: range, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: range, delta: edit.mutation.delta)
            noteDidEdit(range: range, delta: edit.mutation.delta)
            if range.location + range.length <= dropOffset {
                adjustedDrop += edit.mutation.delta
            } else if range.location < dropOffset {
                adjustedDrop = range.location
            }
        }
        let insertRange = NSRange(location: max(0, min(adjustedDrop, document.length)), length: 0)
        noteWillEdit(insertRange)
        let insert = document.replaceCharacters(in: insertRange, with: payload)
        undoCoordinator.register(edit: insert)
        layout.documentDidReplace(range: insert.range, delta: insert.mutation.delta)
        noteDidEdit(range: insert.range, delta: insert.mutation.delta)
        layout.endTransaction()
        undoCoordinator.endGrouping()
        selection.setSelectedRange(
            NSRange(location: insert.range.location, length: payload.utf16.count)
        )
        publishTextChange()
        publishSelectionChange()
    }

    // MARK: - Private

    private func replaceFullText(_ string: String) {
        events.yield(.willChangeText)
        undoCoordinator.clear()
        document.setFullText(string)
        layout.invalidateAll()
        // During language switch the config task will bootstrap after the grammar loads.
        // Skipping a full bootstrap here prevents piled-up load/parse work that freezes the UI,
        // but we must still resync style-container length so stale highlight ranges cannot crash.
        if !languageConfigInFlight {
            highlighter?.documentDidReplaceAll()
        } else {
            highlighter?.updateHooks(makeHighlightHooks())
            highlighter?.syncDocumentLengthOnly()
        }
        selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
        publishTextChange()
        publishSelectionChange()
    }

    private func applyConfiguration(old: EditorConfiguration?) {
        document.defaultAttributes = configuration.typingAttributes
        layout.wrapLines = configuration.wrapLines
        layout.lineHeightMultiplier = configuration.lineHeightMultiplier
        layout.lineBreakStrategy = configuration.lineBreakStrategy
        layout.updateTypingAttributes(configuration.typingAttributes)
        selection.isEnabled = configuration.isSelectable

        // Gutter width contributes to leading content inset.
        let model = makeGutterModel()
        gutterWidth = configuration.peripherals.showGutter ? model.width : 0
        let content = configuration.layout.contentInsets
        layout.edgeInsets = HorizontalEdgeInsets(
            leading: content.leading + gutterWidth,
            trailing: content.trailing
        )

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
        {
            layout.invalidateAll()
        }

        if old != nil, old?.appearance.theme != configuration.appearance.theme {
            highlighter?.updateHooks(makeHighlightHooks())
            highlighter?.themeDidChange()
        }

        updateBracketEmphasis()
    }

    private func publishTextChange() {
        events.yield(.textDidChange)
        events.yieldText(document.fullString)
        // Gutter width may change with line count digit growth.
        let model = makeGutterModel()
        let newGutter = configuration.peripherals.showGutter ? model.width : 0
        if abs(newGutter - gutterWidth) > 0.5 {
            gutterWidth = newGutter
            let content = configuration.layout.contentInsets
            layout.edgeInsets = HorizontalEdgeInsets(
                leading: content.leading + gutterWidth,
                trailing: content.trailing
            )
            layout.invalidateAll()
        }
        for coordinator in liveCoordinators {
            coordinator.textDidChange(controller: self)
        }
        updateBracketEmphasis()
        syncEditorStateCursors()
    }

    private func publishSelectionChange() {
        events.yield(.selectionDidChange)
        events.yieldSelection(selection.selectedRanges)
        let cursors = cursorPositions
        for coordinator in liveCoordinators {
            coordinator.selectionDidChange(controller: self, cursors: cursors)
        }
        updateBracketEmphasis()
        syncEditorStateCursors()
    }

    private func syncEditorStateCursors() {
        editorState.cursorPositions = cursorPositions
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
