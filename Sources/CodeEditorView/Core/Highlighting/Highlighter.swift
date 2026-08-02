import CodeEditorCore
import CodeEditorLanguageSupport
import Foundation

/// Orchestrates highlight providers, merges runs, and paints attributes into the document.
@MainActor
public final class Highlighter {
    public struct DocumentHooks {
        public var length: () -> Int
        public var substring: (NSRange) -> String?
        public var setAttributes: ([NSAttributedString.Key: Any], NSRange) -> Void
        public var typingAttributes: () -> [NSAttributedString.Key: Any]
        public var theme: () -> EditorTheme
        public var font: () -> PlatformFont
        public var invalidateLayout: (NSRange) -> Void
        public var needsDisplay: () -> Void
        /// Current document content version (stale async work is discarded when it changes).
        public var version: () -> DocumentVersion

        public init(
            length: @escaping () -> Int,
            substring: @escaping (NSRange) -> String?,
            setAttributes: @escaping ([NSAttributedString.Key: Any], NSRange) -> Void,
            typingAttributes: @escaping () -> [NSAttributedString.Key: Any],
            theme: @escaping () -> EditorTheme,
            font: @escaping () -> PlatformFont,
            invalidateLayout: @escaping (NSRange) -> Void,
            needsDisplay: @escaping () -> Void,
            version: @escaping () -> DocumentVersion = { .zero }
        ) {
            self.length = length
            self.substring = substring
            self.setAttributes = setAttributes
            self.typingAttributes = typingAttributes
            self.theme = theme
            self.font = font
            self.invalidateLayout = invalidateLayout
            self.needsDisplay = needsDisplay
            self.version = version
        }
    }

    private var hooks: DocumentHooks
    private var providers: [any HighlightProviding] = []
    private var styleContainer: StyledRangeContainer
    private var languageID: String?
    private var dirtyRanges = IndexSet()
    private var visibleRange = NSRange(location: 0, length: 0)
    private var refreshTask: Task<Void, Never>?
    private var editProcessingTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var didInitialVisibleHighlight = false

    /// Serial edit queue so multi-cursor mutations apply incremental tree-sitter edits in order.
    private var pendingEdits: [(range: NSRange, delta: Int, fullText: String)] = []

    /// When true, apply bold/italic from theme captures (can affect line metrics).
    public var applyFontTraits: Bool = false

    /// When true, all provider/bootstrap/refresh work is cancelled and ignored (UI-N09 large-file).
    public var isSuspended: Bool = false {
        didSet {
            if isSuspended {
                cancelPendingWork()
                pendingEdits.removeAll()
            }
        }
    }

    public init(hooks: DocumentHooks) {
        self.hooks = hooks
        self.styleContainer = StyledRangeContainer(documentLength: hooks.length())
        styleContainer.onStylesDidChange = { [weak self] range in
            self?.paint(range: range)
        }
    }

    public func updateHooks(_ hooks: DocumentHooks) {
        self.hooks = hooks
    }

    /// Capture runs for a UTF-16 range (local run offsets mapped to document coordinates).
    public func captureRuns(in range: NSRange) -> [(range: NSRange, capture: CaptureName?)] {
        let runs = styleContainer.runs(in: range)
        var result: [(range: NSRange, capture: CaptureName?)] = []
        var offset = range.location
        for run in runs {
            result.append((NSRange(location: offset, length: run.length), run.value))
            offset += run.length
        }
        return result
    }

    /// Expand the visible invalidation window (e.g. minimap-visible range).
    public func expandVisibleRange(_ range: NSRange) {
        guard range.length > 0 else { return }
        let union = NSUnionRange(visibleRange, range)
        setVisibleUTF16Range(union)
    }

    public func setLanguageID(_ languageID: String?) {
        guard self.languageID != languageID else { return }
        self.languageID = languageID
        // No providers (plain text) — do not schedule a useless bootstrap.
        guard hasProviders, !isSuspended else { return }
        scheduleBootstrap()
    }

    /// Force language id + re-bootstrap even when the id is unchanged (post language-load).
    public func applyLanguageID(_ languageID: String?) {
        self.languageID = languageID
        guard hasProviders else { return }
        scheduleBootstrap()
    }

    /// Cancels in-flight refresh/edit/bootstrap tasks (visibility / lifecycle).
    public func cancelPendingWork() {
        refreshTask?.cancel()
        editProcessingTask?.cancel()
        bootstrapTask?.cancel()
    }

    public func setProviders(_ providers: [any HighlightProviding]) {
        cancelPendingWork()
        pendingEdits.removeAll()
        generation &+= 1
        self.providers = providers
        self.languageID = providers.isEmpty ? nil : languageID
        styleContainer.setProviders(Array(providers.indices))
        didInitialVisibleHighlight = false
        dirtyRanges = IndexSet()

        if providers.isEmpty {
            // Plain text / no highlighting: reset storage once without style-container paint thrash.
            styleContainer.replaceDocumentLength(hooks.length(), notify: false)
            let length = hooks.length()
            if length > 0 {
                let full = NSRange(location: 0, length: length)
                let base = typingAttributesFiltered(hooks.typingAttributes())
                hooks.setAttributes(base, full)
                hooks.invalidateLayout(full)
            }
            hooks.needsDisplay()
            return
        }

        styleContainer.replaceDocumentLength(hooks.length(), notify: false)
        scheduleBootstrap()
    }

    public var hasProviders: Bool { !providers.isEmpty }

    // MARK: - Document events

    public func willApplyEdit(range: NSRange) {
        guard !isSuspended else { return }
        for provider in providers {
            provider.willApplyEdit(range: range)
        }
    }

    public func documentDidEdit(range: NSRange, delta: Int) {
        guard hasProviders, !isSuspended else {
            if hasProviders {
                // Keep style container length coherent without provider work.
                styleContainer.storageEdited(editRange: range, delta: delta)
            }
            return
        }
        styleContainer.storageEdited(editRange: range, delta: delta)
        generation &+= 1

        // Snapshot post-edit document text now (before further mutations).
        let length = hooks.length()
        let fullText = hooks.substring(NSRange(location: 0, length: length)) ?? ""
        pendingEdits.append((range, delta, fullText))
        scheduleEditProcessing()
    }

    private func scheduleEditProcessing() {
        guard editProcessingTask == nil else { return }
        editProcessingTask = Task { [weak self] in
            await self?.processPendingEdits()
        }
    }

    private func processPendingEdits() async {
        while !pendingEdits.isEmpty {
            let batch = pendingEdits
            pendingEdits.removeAll()
            var invalid = IndexSet()
            for edit in batch {
                guard !Task.isCancelled else {
                    editProcessingTask = nil
                    return
                }
                for provider in providers {
                    // Push post-edit text as pending; TreeSitter applies InputEdit incrementally.
                    await provider.setDocumentText(edit.fullText)
                    if let set = try? await provider.applyEdit(range: edit.range, delta: edit.delta) {
                        invalid.formUnion(set)
                    }
                }
            }
            if invalid.isEmpty {
                // Fallback: dirtied by last edit span.
                if let last = batch.last {
                    let length = last.fullText.utf16.count
                    let start = max(0, last.range.location)
                    let end = min(length, last.range.location + max(0, last.range.length + last.delta) + 1)
                    invalid.insert(integersIn: start..<max(start, end))
                }
            }
            dirtyRanges.formUnion(invalid)
            scheduleRefresh()
        }
        editProcessingTask = nil
        // Edits may have arrived while we were finishing.
        if !pendingEdits.isEmpty {
            scheduleEditProcessing()
        }
    }

    public func documentDidReplaceAll() {
        guard hasProviders else {
            syncDocumentLengthOnly()
            return
        }
        generation &+= 1
        refreshTask?.cancel()
        styleContainer.replaceDocumentLength(hooks.length(), notify: false)
        guard !isSuspended else {
            cancelPendingWork()
            return
        }
        scheduleBootstrap()
    }

    /// Resizes the style container to the live document length without querying providers.
    /// Used when text is replaced during an in-flight language load.
    public func syncDocumentLengthOnly() {
        generation &+= 1
        refreshTask?.cancel()
        styleContainer.replaceDocumentLength(hooks.length(), notify: false)
        dirtyRanges = IndexSet()
        didInitialVisibleHighlight = false
    }

    public func invalidateAll() {
        guard !isSuspended else {
            cancelPendingWork()
            return
        }
        let length = hooks.length()
        dirtyRanges = IndexSet(integersIn: 0..<max(0, length))
        didInitialVisibleHighlight = false
        scheduleRefresh()
    }

    public func themeDidChange() {
        // Re-paint whatever is already styled in the visible range.
        if visibleRange.length > 0 {
            paint(range: visibleRange)
        }
        invalidateAll()
    }

    public func setVisibleUTF16Range(_ range: NSRange) {
        guard !isSuspended else { return }
        let length = hooks.length()
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let pad = 200
        let start = max(0, clamped.location - pad)
        let end = min(length, clamped.location + clamped.length + pad)
        let padded = NSRange(location: start, length: max(0, end - start))
        let changed = padded != visibleRange
        visibleRange = padded
        guard hasProviders, visibleRange.length > 0 else { return }
        if changed || !didInitialVisibleHighlight || !dirtyRanges.isEmpty {
            if dirtyRanges.isEmpty {
                dirtyRanges.insert(integersIn: visibleRange.location..<(visibleRange.location + visibleRange.length))
            }
            scheduleRefresh()
        }
    }

    // MARK: - Private

    private func scheduleBootstrap() {
        guard !isSuspended else {
            cancelPendingWork()
            return
        }
        bootstrapTask?.cancel()
        generation &+= 1
        let gen = generation
        bootstrapTask = Task { [weak self] in
            await self?.bootstrapProviders(generation: gen)
        }
    }

    private func bootstrapProviders(generation gen: UInt64) async {
        guard gen == generation, !isSuspended else { return }
        let startVersion = hooks.version()
        let length = hooks.length()
        styleContainer.replaceDocumentLength(length)
        // Snapshot after any prior cancellation point; re-read again after provider setup.
        var fullText = hooks.substring(NSRange(location: 0, length: length)) ?? ""
        for provider in providers {
            guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
            await provider.setUp(documentLength: hooks.length(), languageID: languageID)
            guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
            // Document may have changed while queries compiled.
            let latestLength = hooks.length()
            fullText = hooks.substring(NSRange(location: 0, length: latestLength)) ?? ""
            await provider.setDocumentText(fullText)
        }
        guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
        // Final sync: if text changed during the last parse, re-push once more.
        let finalLength = hooks.length()
        let finalText = hooks.substring(NSRange(location: 0, length: finalLength)) ?? ""
        if finalText != fullText {
            for provider in providers {
                guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
                await provider.setDocumentText(finalText)
            }
        }
        guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
        styleContainer.replaceDocumentLength(hooks.length())
        invalidateAll()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let gen = generation
        let version = hooks.version()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            guard self.hooks.version() == version else { return }
            await self.refreshVisible()
        }
    }

    private func refreshVisible() async {
        let length = hooks.length()
        guard length > 0, hasProviders else {
            dirtyRanges = IndexSet()
            return
        }

        let visible = NSIntersectionRange(visibleRange, NSRange(location: 0, length: length))
        guard visible.length > 0 else { return }

        var work = dirtyRanges
        if work.isEmpty {
            work.insert(integersIn: visible.location..<(visible.location + visible.length))
        } else {
            work.formIntersection(IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
        }
        guard !work.isEmpty else { return }

        let ranges = work.rangeView.map {
            NSRange(location: $0.lowerBound, length: $0.upperBound - $0.lowerBound)
        }

        let gen = generation
        let startVersion = hooks.version()
        for range in ranges {
            guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
            guard let text = hooks.substring(range) else { continue }
            for (index, provider) in providers.enumerated() {
                guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
                do {
                    let highlights = try await provider.queryHighlights(in: range, text: text)
                    guard !Task.isCancelled, gen == generation, hooks.version() == startVersion else { return }
                    styleContainer.setHighlights(highlights, forProvider: index, in: range)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
            dirtyRanges.remove(integersIn: range.location..<(range.location + range.length))
        }
        guard gen == generation, hooks.version() == startVersion else { return }
        didInitialVisibleHighlight = true
    }

    private func paint(range: NSRange) {
        // Attribute paints must never run against a document that moved under us mid-refresh.
        // (style container callbacks can race with a newer edit generation.)
        let length = hooks.length()
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard clamped.length > 0 else { return }

        // Always start from clean typing attributes for this span, then layer captures.
        let base = typingAttributesFiltered(hooks.typingAttributes())
        hooks.setAttributes(base, clamped)

        let theme = hooks.theme()
        let font = hooks.font()
        var offset = clamped.location
        for run in styleContainer.runs(in: clamped) {
            let runRange = NSRange(location: offset, length: run.length)
            offset += run.length
            guard let capture = run.value else { continue }
            var attrs = base
            attrs[.foregroundColor] = theme.color(for: capture)
            if applyFontTraits {
                attrs[.font] = theme.font(for: capture, base: font)
            } else {
                attrs[.font] = font
            }
            hooks.setAttributes(attrs, runRange)
        }

        hooks.invalidateLayout(clamped)
        hooks.needsDisplay()
    }

    private func typingAttributesFiltered(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var result = attrs
        if result[.font] == nil {
            result[.font] = hooks.font()
        }
        if result[.foregroundColor] == nil {
            result[.foregroundColor] = hooks.theme().text.color
        }
        return result
    }
}
