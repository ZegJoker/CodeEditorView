import CoreGraphics
import Foundation
import Observation
import TextStory

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
        didSet { applyConfiguration() }
    }

    public var invisibleCharactersDelegate: InvisibleCharactersDelegate? {
        didSet { /* hosts redraw */ }
    }

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
        configuration: EditorConfiguration = EditorConfiguration()
    ) {
        self.configuration = configuration
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
        applyConfiguration()
    }

    // MARK: - Editing

    public func replaceCharacters(in range: NSRange, with string: String) {
        guard configuration.isEditable else { return }
        events.yield(.willChangeText)
        layout.beginTransaction()
        let edit = document.replaceCharacters(in: range, with: string)
        undoCoordinator.register(edit: edit)
        layout.documentDidReplace(range: range, delta: edit.mutation.delta)
        layout.endTransaction()
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
        undoCoordinator.beginGrouping()
        layout.beginTransaction()
        let edits = selection.replaceAllSelections(with: string)
        for edit in edits {
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
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
            let edit = document.replaceCharacters(in: deleteRange, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: deleteRange, delta: edit.mutation.delta)
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
            let edit = document.replaceCharacters(in: deleteRange, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: deleteRange, delta: edit.mutation.delta)
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
            self.layout.beginTransaction()
            self.document.applyMutation(edit.inverse)
            self.layout.documentDidReplace(range: edit.inverse.range, delta: edit.inverse.delta)
            self.layout.endTransaction()
            self.selection.setInsertionPoint(edit.inverse.range.location + edit.inverse.string.utf16.count)
        }
        publishTextChange()
        publishSelectionChange()
    }

    public func redo() {
        undoCoordinator.redo { [weak self] edit in
            guard let self else { return }
            self.events.yield(.willChangeText)
            self.layout.beginTransaction()
            self.document.applyMutation(edit.mutation)
            self.layout.documentDidReplace(range: edit.mutation.range, delta: edit.mutation.delta)
            self.layout.endTransaction()
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
            let edit = document.replaceCharacters(in: range, with: "")
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: range, delta: edit.mutation.delta)
            if range.location + range.length <= dropOffset {
                adjustedDrop += edit.mutation.delta
            } else if range.location < dropOffset {
                adjustedDrop = range.location
            }
        }
        let insert = document.replaceCharacters(
            in: NSRange(location: max(0, min(adjustedDrop, document.length)), length: 0),
            with: payload
        )
        undoCoordinator.register(edit: insert)
        layout.documentDidReplace(range: insert.range, delta: insert.mutation.delta)
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
        selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
        publishTextChange()
        publishSelectionChange()
    }

    private func applyConfiguration() {
        document.defaultAttributes = configuration.typingAttributes
        layout.wrapLines = configuration.wrapLines
        layout.lineHeightMultiplier = configuration.lineHeightMultiplier
        layout.lineBreakStrategy = configuration.lineBreakStrategy
        layout.edgeInsets = configuration.edgeInsets
        layout.updateTypingAttributes(configuration.typingAttributes)
        selection.isEnabled = configuration.isSelectable
        if configuration.showInvisibleCharacters, invisibleCharactersDelegate == nil {
            invisibleCharactersDelegate = DefaultInvisibleCharactersDelegate()
        }
        layout.invalidateAll()
    }

    private func publishTextChange() {
        events.yield(.textDidChange)
        events.yieldText(document.fullString)
    }

    private func publishSelectionChange() {
        events.yield(.selectionDidChange)
        events.yieldSelection(selection.selectedRanges)
    }
}
