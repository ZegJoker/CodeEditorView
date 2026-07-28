#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import CoreText

/// AppKit host view for ``EditorController``.
open class AppKitEditorView: NSView, @preconcurrency NSTextInputClient, NSDraggingSource {
    public let controller: EditorController

    private let blink = CursorBlinkController()
    private var markedRangeStorage = NSRange(location: NSNotFound, length: 0)
    private var containerWidth: CGFloat = 0
    private var isFirstResponderFlag = false
    private var selectionAnchor: Int?
    private var columnAnchor: CGPoint?
    nonisolated(unsafe) private var dragScrollTask: Task<Void, Never>?
    private var isReceivingDrag = false

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?

    public init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        canDrawConcurrently = false
        registerForDraggedTypes([.string])

        blink.onChange = { [weak self] _ in
            self?.needsDisplay = true
        }
        controller.emphasis.onChange = { [weak self] in
            self?.needsDisplay = true
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        dragScrollTask?.cancel()
    }

    open override var acceptsFirstResponder: Bool { controller.configuration.isSelectable }
    open override var isFlipped: Bool { true }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout()
    }

    open override func layout() {
        super.layout()
        relayout()
    }

    @objc private func frameDidChange() {
        relayout()
    }

    public func relayout() {
        containerWidth = bounds.width
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        let snapshot = controller.layoutViewport(visibleRect: visible, containerWidth: containerWidth)
        let size = snapshot.contentSize
        let width = controller.configuration.wrapLines
            ? (superview?.bounds.width ?? bounds.width)
            : max(bounds.width, size.width)
        let height = max(size.height, superview?.bounds.height ?? size.height)
        if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
        scrollToSelectionIfNeeded()
        needsDisplay = true
    }

    private func scrollToSelectionIfNeeded() {
        guard let target = controller.scrollTarget else { return }
        scrollToVisible(target)
    }

    // MARK: - Drawing

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let visible = dirtyRect.union(visibleRect)
        let width = containerWidth > 0 ? containerWidth : bounds.width
        let snapshot = controller.layoutViewport(visibleRect: visible, containerWidth: width)

        EmphasisRenderer.draw(
            controller.emphasis.items,
            fragments: snapshot.fragments,
            in: context,
            standardFill: controller.configuration.emphasisFillColor.cgColor,
            outlineStroke: controller.configuration.emphasisStrokeColor.cgColor
        )

        LineFragmentRenderer.drawSelection(
            ranges: controller.selectedRanges,
            fragments: snapshot.fragments,
            in: context,
            color: controller.configuration.selectionColor.cgColor
        )

        for item in snapshot.fragments {
            LineFragmentRenderer.draw(item.fragment, in: context, origin: item.frame.origin)
        }

        if controller.configuration.showInvisibleCharacters,
           let delegate = controller.invisibleCharactersDelegate {
            let ctFont = controller.configuration.font as CTFont
            InvisibleCharacterRenderer.draw(
                delegate: delegate,
                document: controller.document,
                fragments: snapshot.fragments,
                in: context,
                font: ctFont
            )
        }

        if isFirstResponderFlag {
            let offsets = controller.selectedRanges.filter { $0.length == 0 }.map(\.location)
            LineFragmentRenderer.drawCarets(
                offsets: offsets,
                layout: controller.layout,
                containerWidth: width,
                in: context,
                color: controller.configuration.caretColor.cgColor,
                visible: blink.isVisible
            )
        }
    }

    // MARK: - First responder

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFirstResponderFlag = true
            blink.start()
            needsDisplay = true
        }
        return ok
    }

    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            isFirstResponderFlag = false
            blink.stop()
            needsDisplay = true
        }
        return ok
    }

    // MARK: - Mouse

    open override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)

        if event.modifierFlags.contains(.option) {
            if event.modifierFlags.contains(.shift) {
                // Start column selection
                columnAnchor = point
                controller.selection.mode = .column
                controller.applyColumnSelection(
                    rect: CGRect(origin: point, size: .zero),
                    containerWidth: containerWidth
                )
            } else {
                controller.addCursor(at: offset)
            }
        } else if event.modifierFlags.contains(.shift), let anchor = selectionAnchor {
            controller.setSelectedRange(
                NSRange(location: min(anchor, offset), length: abs(anchor - offset))
            )
        } else {
            selectionAnchor = offset
            columnAnchor = nil
            controller.selection.mode = .character
            controller.setSelectedRange(NSRange(location: offset, length: 0))
        }
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startDragScrollIfNeeded(point: point)

        if controller.selection.mode == .column, let anchor = columnAnchor {
            let rect = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(anchor.x - point.x),
                height: abs(anchor.y - point.y)
            )
            controller.applyColumnSelection(rect: rect, containerWidth: containerWidth)
        } else {
            let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
            let anchor = selectionAnchor ?? controller.selectedRange.location
            selectionAnchor = anchor
            controller.setSelectedRange(
                NSRange(location: min(anchor, offset), length: abs(anchor - offset))
            )
        }
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func mouseUp(with event: NSEvent) {
        dragScrollTask?.cancel()
        dragScrollTask = nil
        columnAnchor = nil
    }

    private func startDragScrollIfNeeded(point: CGPoint) {
        let visible = visibleRect
        let edge: CGFloat = 24
        let nearEdge = point.y < visible.minY + edge || point.y > visible.maxY - edge
            || point.x < visible.minX + edge || point.x > visible.maxX - edge
        guard nearEdge else {
            dragScrollTask?.cancel()
            dragScrollTask = nil
            return
        }
        guard dragScrollTask == nil else { return }
        dragScrollTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    var rect = self.visibleRect
                    let p = self.convert(self.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
                    if p.y < rect.minY + edge { rect.origin.y -= 12 }
                    if p.y > rect.maxY - edge { rect.origin.y += 12 }
                    if p.x < rect.minX + edge { rect.origin.x -= 12 }
                    if p.x > rect.maxX - edge { rect.origin.x += 12 }
                    self.scrollToVisible(rect)
                }
            }
        }
    }

    // MARK: - Keyboard

    open override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
            return
        }
        if event.keyCode == 53 { // Escape
            controller.collapseCursors()
            onSelectionChange?(controller.selectedRange)
            needsDisplay = true
            return
        }
        interpretKeyEvents([event])
    }

    open override func insertText(_ insertString: Any) {
        let string: String
        if let s = insertString as? String { string = s }
        else if let s = insertString as? NSAttributedString { string = s.string }
        else { return }
        controller.insertText(string)
        blink.reset()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    open override func deleteBackward(_ sender: Any?) {
        controller.deleteBackward()
        finishEdit()
    }

    open override func deleteForward(_ sender: Any?) {
        controller.deleteForward()
        finishEdit()
    }

    open override func moveLeft(_ sender: Any?) {
        controller.move(direction: .left, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveRight(_ sender: Any?) {
        controller.move(direction: .right, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveUp(_ sender: Any?) {
        controller.move(direction: .up, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveDown(_ sender: Any?) {
        controller.move(direction: .down, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveWordLeft(_ sender: Any?) {
        controller.move(direction: .left, granularity: .word, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveWordRight(_ sender: Any?) {
        controller.move(direction: .right, granularity: .word, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveToBeginningOfLine(_ sender: Any?) {
        controller.move(direction: .left, granularity: .line, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveToEndOfLine(_ sender: Any?) {
        controller.move(direction: .right, granularity: .line, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveToBeginningOfDocument(_ sender: Any?) {
        controller.move(direction: .left, granularity: .document, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveToEndOfDocument(_ sender: Any?) {
        controller.move(direction: .right, granularity: .document, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveLeftAndModifySelection(_ sender: Any?) {
        controller.move(direction: .left, extending: true, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveRightAndModifySelection(_ sender: Any?) {
        controller.move(direction: .right, extending: true, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveUpAndModifySelection(_ sender: Any?) {
        controller.move(direction: .up, extending: true, containerWidth: containerWidth)
        finishSelection()
    }

    open override func moveDownAndModifySelection(_ sender: Any?) {
        controller.move(direction: .down, extending: true, containerWidth: containerWidth)
        finishSelection()
    }

    open override func selectAll(_ sender: Any?) {
        controller.selectAll()
        finishSelection()
    }

    @objc public func undo(_ sender: Any?) {
        controller.undo()
        finishEdit()
    }

    @objc public func redo(_ sender: Any?) {
        controller.redo()
        finishEdit()
    }

    @objc public func copy(_ sender: Any?) {
        let text = controller.text(in: controller.selectedRanges)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        copy(sender)
        controller.insertText("")
        finishEdit()
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        controller.insertText(text)
        finishEdit()
    }

    private func finishEdit() {
        blink.reset()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    private func finishSelection() {
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        scrollToSelectionIfNeeded()
        needsDisplay = true
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        insertText(string)
        markedRangeStorage = NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String { text = s }
        else if let s = string as? NSAttributedString { text = s.string }
        else { return }

        if replacementRange.location != NSNotFound {
            controller.replaceCharacters(in: replacementRange, with: text)
        } else if markedRangeStorage.location != NSNotFound {
            controller.replaceCharacters(in: markedRangeStorage, with: text)
        } else {
            controller.insertText(text)
        }
        markedRangeStorage = NSRange(
            location: controller.selectedRange.location - text.utf16.count,
            length: text.utf16.count
        )
        onTextChange?(controller.text)
        relayout()
    }

    public func unmarkText() {
        markedRangeStorage = NSRange(location: NSNotFound, length: 0)
    }

    public func selectedRange() -> NSRange { controller.selectedRange }
    public func markedRange() -> NSRange { markedRangeStorage }
    public func hasMarkedText() -> Bool { markedRangeStorage.location != NSNotFound }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = range
        return controller.document.attributedSubstring(from: range)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let caret = controller.layout.caretRect(atUTF16Offset: range.location, containerWidth: containerWidth) else {
            return .zero
        }
        let rect = convert(caret, to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    public func characterIndex(for point: NSPoint) -> Int {
        let local = convert(window?.convertPoint(fromScreen: point) ?? point, from: nil)
        return controller.hitTestOffset(at: local, containerWidth: containerWidth)
    }

    // MARK: - Drag and drop

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : .move
    }

    open override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isReceivingDrag = true
        return .move
    }

    open override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        controller.setSelectedRange(NSRange(location: offset, length: 0))
        needsDisplay = true
        return .move
    }

    open override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = sender.draggingPasteboard.string(forType: .string) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        controller.setSelectedRange(NSRange(location: offset, length: 0))
        controller.insertText(text)
        finishEdit()
        isReceivingDrag = false
        return true
    }

    open override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isReceivingDrag = false
    }

    // MARK: - Accessibility

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    open override func accessibilityValue() -> Any? { controller.text }
    open override func accessibilitySelectedText() -> String? {
        controller.text(in: controller.selectedRanges)
    }
    open override func accessibilitySelectedTextRange() -> NSRange {
        controller.selectedRange
    }
    open override func accessibilityNumberOfCharacters() -> Int {
        controller.document.length
    }
    open override func accessibilityInsertionPointLineNumber() -> Int {
        controller.layout.lineIndex.line(atUTF16Offset: controller.selectedRange.location)?.index ?? 0
    }
    open override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let caret = controller.layout.caretRect(atUTF16Offset: range.location, containerWidth: containerWidth) else {
            return .zero
        }
        return convert(caret, to: nil)
    }
    open override func accessibilityString(for range: NSRange) -> String? {
        controller.document.substring(from: range)
    }
}
#endif
