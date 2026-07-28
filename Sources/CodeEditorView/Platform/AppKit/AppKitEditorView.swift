#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics

/// AppKit host view for ``EditorController``.
open class AppKitEditorView: NSView, @preconcurrency NSTextInputClient {
    public let controller: EditorController

    private let blink = CursorBlinkController()
    private var markedRangeStorage = NSRange(location: NSNotFound, length: 0)
    private var containerWidth: CGFloat = 0
    private var isFirstResponderFlag = false

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?

    public init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        canDrawConcurrently = false

        blink.onChange = { [weak self] _ in
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
        if abs(frame.height - size.height) > 0.5 || (!controller.configuration.wrapLines && abs(frame.width - max(bounds.width, size.width)) > 0.5) {
            let width = controller.configuration.wrapLines ? (superview?.bounds.width ?? bounds.width) : max(bounds.width, size.width)
            setFrameSize(NSSize(width: width, height: max(size.height, superview?.bounds.height ?? size.height)))
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let visible = dirtyRect.union(visibleRect)
        let snapshot = controller.layoutViewport(visibleRect: visible, containerWidth: containerWidth > 0 ? containerWidth : bounds.width)

        LineFragmentRenderer.drawSelection(
            range: controller.selectedRange,
            fragments: snapshot.fragments,
            in: context,
            color: controller.configuration.selectionColor.cgColor
        )

        for item in snapshot.fragments {
            LineFragmentRenderer.draw(
                item.fragment,
                in: context,
                origin: item.frame.origin
            )
        }

        if isFirstResponderFlag,
           controller.selectedRange.length == 0,
           blink.isVisible,
           let caret = controller.caretRect(containerWidth: containerWidth > 0 ? containerWidth : bounds.width) {
            context.setFillColor(controller.configuration.caretColor.cgColor)
            context.fill(CGRect(x: caret.minX, y: caret.minY, width: 1.5, height: caret.height))
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
        if event.modifierFlags.contains(.shift) {
            let anchor = controller.selectedRange.location
            let location = min(anchor, offset)
            let length = abs(anchor - offset)
            controller.setSelectedRange(NSRange(location: location, length: length))
        } else {
            controller.setSelectedRange(NSRange(location: offset, length: 0))
        }
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        let anchor = controller.selectedRange.location
        // Use selection start as anchor when dragging from insertion point.
        let start = controller.selectedRange.length == 0 ? controller.selectedRange.location : controller.selectedRange.location
        _ = start
        let origin = (window?.currentEvent == event) ? offset : controller.selectedRange.location
        // Anchor is the original mouse-down location tracked via selected range start when length grows.
        // Simplified: extend from current selection location.
        let base = controller.selectedRange.location
        let location = min(base, offset)
        let length = abs(base - offset)
        // If we had an insertion point, use it as anchor.
        if controller.selectedRange.length == 0 {
            controller.setSelectedRange(NSRange(location: min(anchor, offset), length: abs(anchor - offset)))
        } else {
            controller.setSelectedRange(NSRange(location: location, length: length))
        }
        _ = origin
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    // MARK: - Keyboard

    open override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    open override func insertText(_ insertString: Any) {
        let string: String
        if let s = insertString as? String {
            string = s
        } else if let s = insertString as? NSAttributedString {
            string = s.string
        } else {
            return
        }
        controller.insertText(string)
        blink.reset()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    open override func deleteBackward(_ sender: Any?) {
        controller.deleteBackward()
        blink.reset()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    open override func deleteForward(_ sender: Any?) {
        controller.deleteForward()
        blink.reset()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    open override func moveLeft(_ sender: Any?) {
        controller.move(direction: .left, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func moveRight(_ sender: Any?) {
        controller.move(direction: .right, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func moveUp(_ sender: Any?) {
        controller.move(direction: .up, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func moveDown(_ sender: Any?) {
        controller.move(direction: .down, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func moveLeftAndModifySelection(_ sender: Any?) {
        controller.move(direction: .left, extending: true, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func moveRightAndModifySelection(_ sender: Any?) {
        controller.move(direction: .right, extending: true, containerWidth: containerWidth)
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    open override func selectAll(_ sender: Any?) {
        controller.selectAll()
        onSelectionChange?(controller.selectedRange)
        needsDisplay = true
    }

    @objc public func undo(_ sender: Any?) {
        controller.undo()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc public func redo(_ sender: Any?) {
        controller.redo()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc public func copy(_ sender: Any?) {
        let range = controller.selectedRange
        guard range.length > 0, let text = controller.document.substring(from: range) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func cut(_ sender: Any?) {
        copy(sender)
        controller.insertText("")
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        controller.insertText(text)
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
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
        markedRangeStorage = NSRange(location: controller.selectedRange.location - text.utf16.count, length: text.utf16.count)
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
}
#endif
