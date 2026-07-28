import CoreGraphics
import Foundation
import Observation
import TextStory

/// Central editor model: document, layout, selection, undo, and event streams.
@MainActor
@Observable
public final class EditorController {
    public private(set) var document: DocumentStore
    public let layout: LayoutEngine
    public let selection: SelectionEngine
    public let undoCoordinator: UndoCoordinator
    public let events: EditorEventStream

    public var configuration: EditorConfiguration {
        didSet { applyConfiguration() }
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

    public private(set) var contentSize: CGSize = .zero
    public private(set) var latestSnapshot: LayoutSnapshot = .empty

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

        layout.attach(document: document, typingAttributes: configuration.typingAttributes)
        selection.attach(document: document, layout: layout)
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

        let newLocation = range.location + string.utf16.count
        selection.setInsertionPoint(newLocation)
        publishTextChange()
        publishSelectionChange()
    }

    public func insertText(_ string: String) {
        guard configuration.isEditable else { return }
        if let edit = selection.replaceSelection(with: string) {
            events.yield(.willChangeText)
            layout.beginTransaction()
            // SelectionEngine already applied the mutation via document.
            // Re-register: DocumentStore was mutated inside replaceSelection.
            // Rebuild layout for the applied mutation.
            undoCoordinator.register(edit: edit)
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
            layout.endTransaction()
            publishTextChange()
            publishSelectionChange()
        }
    }

    public func deleteBackward() {
        guard configuration.isEditable else { return }
        let range = selection.selectedRange
        if range.length > 0 {
            replaceCharacters(in: range, with: "")
            return
        }
        guard range.location > 0 else { return }
        replaceCharacters(in: NSRange(location: range.location - 1, length: 1), with: "")
    }

    public func deleteForward() {
        guard configuration.isEditable else { return }
        let range = selection.selectedRange
        if range.length > 0 {
            replaceCharacters(in: range, with: "")
            return
        }
        guard range.location < document.length else { return }
        replaceCharacters(in: NSRange(location: range.location, length: 1), with: "")
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
        publishSelectionChange()
    }

    public func selectAll() {
        selection.selectAll()
        publishSelectionChange()
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

    public func hitTestOffset(at point: CGPoint, containerWidth: CGFloat) -> Int {
        layout.utf16Offset(at: point, containerWidth: containerWidth)
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
        layout.invalidateAll()
    }

    private func publishTextChange() {
        events.yield(.textDidChange)
        events.yieldText(document.fullString)
    }

    private func publishSelectionChange() {
        events.yield(.selectionDidChange)
        events.yieldSelection([selection.selectedRange])
    }
}
