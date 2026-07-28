#if canImport(UIKit) && !os(macOS)
import UIKit
import CoreGraphics
import CoreText

/// UIKit host view for ``EditorController`` with `UITextInput` and accessibility.
open class UIKitEditorView: UIView, UITextInput, UIKeyInput, UIDragInteractionDelegate, UIDropInteractionDelegate {
    public let controller: EditorController

    private let blink = CursorBlinkController()
    private var containerWidth: CGFloat = 0
    private var inputDelegateStorage: UITextInputDelegate?
    private var tokenizerStorage: UITextInputTokenizer!
    private var selectionAnchor: Int?

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?

    public var selectedTextRange: UITextRange? {
        get { EditorTextRange(range: controller.selectedRange) }
        set {
            if let editorRange = newValue as? EditorTextRange {
                controller.setSelectedRange(editorRange.range)
                onSelectionChange?(controller.selectedRange)
                blink.reset()
                setNeedsDisplay()
            }
        }
    }

    public var markedTextRange: UITextRange? { nil }
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    public var beginningOfDocument: UITextPosition { EditorTextPosition(offset: 0) }
    public var endOfDocument: UITextPosition { EditorTextPosition(offset: controller.document.length) }
    public var inputDelegate: UITextInputDelegate? {
        get { inputDelegateStorage }
        set { inputDelegateStorage = newValue }
    }
    public var tokenizer: UITextInputTokenizer { tokenizerStorage }

    public init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = controller.configuration.appearance.useThemeBackground
            ? controller.configuration.theme.background
            : .systemBackground
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        tokenizerStorage = UITextInputStringTokenizer(textInput: self)

        blink.onChange = { [weak self] _ in self?.setNeedsDisplay() }
        controller.emphasis.onChange = { [weak self] in self?.setNeedsDisplay() }
        controller.onNeedsDisplay = { [weak self] in self?.setNeedsDisplay() }

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        addGestureRecognizer(singleTap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let drag = UIDragInteraction(delegate: self)
        addInteraction(drag)
        let drop = UIDropInteraction(delegate: self)
        addInteraction(drop)
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            controller.notifyDidAppear()
        } else {
            controller.notifyDidDisappear()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override var canBecomeFirstResponder: Bool {
        controller.configuration.isEditable || controller.configuration.isSelectable
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        relayout()
    }

    public func relayout() {
        let layoutWidth = max(1, bounds.width)
        if abs(containerWidth - layoutWidth) > 0.5, controller.configuration.wrapLines {
            controller.layout.invalidateAll()
        }
        containerWidth = layoutWidth
        _ = controller.layoutViewport(visibleRect: bounds, containerWidth: layoutWidth)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    open override var intrinsicContentSize: CGSize {
        let width = controller.configuration.wrapLines ? UIView.noIntrinsicMetric : controller.contentSize.width
        return CGSize(width: width, height: max(controller.contentSize.height, 1))
    }

    open override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let width = containerWidth > 0 ? containerWidth : bounds.width
        let snapshot = controller.layoutViewport(visibleRect: rect.union(bounds), containerWidth: width)
        let theme = controller.configuration.theme
        let gutterWidth = controller.gutterWidth
        let selectedLines = controller.selectedLineIndices
        let visible = rect.union(bounds)

        if controller.configuration.appearance.useThemeBackground {
            context.setFillColor(theme.background.cgColor)
            context.fill(visible)
        }

        if controller.configuration.isEditable {
            ChromeRenderer.drawLineHighlights(
                lineIndices: selectedLines,
                lineIndex: controller.layout.lineIndex,
                contentWidth: max(width, bounds.width),
                gutterWidth: gutterWidth,
                color: theme.lineHighlight.cgColor,
                in: context
            )
        }

        if controller.configuration.peripherals.showReformattingGuide {
            ChromeRenderer.drawReformattingGuide(
                column: controller.configuration.behavior.reformatAtColumn,
                characterWidth: controller.configuration.characterWidth,
                textLeadingInset: controller.layout.edgeInsets.leading,
                visibleRect: visible,
                color: theme.reformattingGuide.cgColor,
                in: context
            )
        }

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
            InvisibleCharacterRenderer.draw(
                delegate: delegate,
                document: controller.document,
                fragments: snapshot.fragments,
                in: context,
                font: controller.configuration.font as CTFont
            )
        }

        if controller.configuration.peripherals.showGutter {
            let model = controller.makeGutterModel()
            GutterRenderer.draw(
                model: model,
                lineIndex: controller.layout.lineIndex,
                visibleRect: visible,
                selectedLineIndices: selectedLines,
                textColor: theme.gutterText.cgColor,
                selectedTextColor: theme.text.color.cgColor,
                backgroundColor: theme.gutterBackground.cgColor,
                selectedLineColor: theme.lineHighlight.cgColor,
                in: context
            )
        }

        if isFirstResponder {
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

    // MARK: - Gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        _ = becomeFirstResponder()
        let point = gesture.location(in: self)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        if gesture.numberOfTouches > 1 {
            controller.addCursor(at: offset)
        } else {
            selectionAnchor = offset
            controller.setSelectedRange(NSRange(location: offset, length: 0))
        }
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        setNeedsDisplay()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        _ = becomeFirstResponder()
        let point = gesture.location(in: self)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        controller.selectWord(atUTF16Offset: offset)
        selectionAnchor = controller.selectedRange.location
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        setNeedsDisplay()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        _ = becomeFirstResponder()
        let point = gesture.location(in: self)
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        if gesture.state == .began {
            selectionAnchor = offset
            controller.setSelectedRange(NSRange(location: offset, length: 0))
        } else {
            let anchor = selectionAnchor ?? controller.selectedRange.location
            controller.setSelectedRange(NSRange(location: min(anchor, offset), length: abs(anchor - offset)))
        }
        blink.reset()
        onSelectionChange?(controller.selectedRange)
        setNeedsDisplay()
    }

    open override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { blink.start() }
        return ok
    }

    open override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { blink.stop() }
        return ok
    }

    // MARK: - UIKeyInput

    public var hasText: Bool { controller.document.length > 0 }

    public func insertText(_ text: String) {
        inputDelegate?.textWillChange(self)
        if text == "\t" {
            controller.insertTab()
        } else if text == "\n" || text == "\r" {
            controller.insertNewline()
        } else {
            controller.insertText(text)
        }
        inputDelegate?.textDidChange(self)
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    public func deleteBackward() {
        inputDelegate?.textWillChange(self)
        controller.deleteBackward()
        inputDelegate?.textDidChange(self)
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    open override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = [
            UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleBacktab)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(handleOutdent)),
            UIKeyCommand(input: "]", modifierFlags: .command, action: #selector(handleIndent)),
            UIKeyCommand(input: "/", modifierFlags: .command, action: #selector(handleToggleComment)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .alternate, action: #selector(handleMoveLinesUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: .alternate, action: #selector(handleMoveLinesDown)),
            UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(handleToggleCompletions)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
        ]
        if controller.completionsVisible {
            commands.append(contentsOf: [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleCompletionUp)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleCompletionDown)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleCompletionApply)),
            ])
        }
        return commands
    }

    @objc private func handleToggleCompletions() {
        if controller.completionsVisible {
            controller.hideCompletions()
        } else {
            controller.showCompletions()
        }
        setNeedsDisplay()
    }

    @objc private func handleEscape() {
        if controller.findSession.isShowing {
            controller.hideFindPanel()
        } else if controller.completionsVisible {
            controller.hideCompletions()
        } else if controller.completionDelegate != nil {
            controller.showCompletions()
        }
        setNeedsDisplay()
    }

    @objc private func handleCompletionUp() {
        controller.moveCompletionSelection(delta: -1)
        setNeedsDisplay()
    }

    @objc private func handleCompletionDown() {
        controller.moveCompletionSelection(delta: 1)
        setNeedsDisplay()
    }

    @objc private func handleCompletionApply() {
        controller.applyCompletionSelection()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleBacktab() {
        controller.insertBacktab()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleIndent() {
        controller.indentSelection()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleOutdent() {
        controller.outdentSelection()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleToggleComment() {
        controller.toggleLineComment()
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleMoveLinesUp() {
        controller.moveSelectedLines(up: true)
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    @objc private func handleMoveLinesDown() {
        controller.moveSelectedLines(up: false)
        onTextChange?(controller.text)
        onSelectionChange?(controller.selectedRange)
        relayout()
    }

    // MARK: - UITextInput

    public func text(in range: UITextRange) -> String? {
        guard let editorRange = range as? EditorTextRange else { return nil }
        return controller.document.substring(from: editorRange.range)
    }

    public func replace(_ range: UITextRange, withText text: String) {
        guard let editorRange = range as? EditorTextRange else { return }
        inputDelegate?.textWillChange(self)
        controller.replaceCharacters(in: editorRange.range, with: text)
        inputDelegate?.textDidChange(self)
        onTextChange?(controller.text)
        relayout()
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if let markedText { insertText(markedText) }
    }

    public func unmarkText() {}

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? EditorTextPosition,
              let to = toPosition as? EditorTextPosition else { return nil }
        let location = min(from.offset, to.offset)
        return EditorTextRange(range: NSRange(location: location, length: abs(from.offset - to.offset)))
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? EditorTextPosition else { return nil }
        let next = min(max(0, pos.offset + offset), controller.document.length)
        return EditorTextPosition(offset: next)
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        let delta: Int
        switch direction {
        case .left, .up: delta = -offset
        case .right, .down: delta = offset
        @unknown default: delta = offset
        }
        return self.position(from: position, offset: delta)
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? EditorTextPosition, let b = other as? EditorTextPosition else { return .orderedSame }
        if a.offset < b.offset { return .orderedAscending }
        if a.offset > b.offset { return .orderedDescending }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? EditorTextPosition, let b = toPosition as? EditorTextPosition else { return 0 }
        return b.offset - a.offset
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let editorRange = range as? EditorTextRange else { return nil }
        switch direction {
        case .left, .up: return EditorTextPosition(offset: editorRange.range.location)
        case .right, .down: return EditorTextPosition(offset: editorRange.range.location + editorRange.range.length)
        @unknown default: return EditorTextPosition(offset: editorRange.range.location)
        }
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let pos = position as? EditorTextPosition else { return nil }
        let next = self.position(from: pos, in: direction, offset: 1) as? EditorTextPosition
        let end = next?.offset ?? pos.offset
        return EditorTextRange(range: NSRange(location: min(pos.offset, end), length: abs(pos.offset - end)))
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    public func firstRect(for range: UITextRange) -> CGRect {
        guard let editorRange = range as? EditorTextRange else { return .zero }
        return controller.layout.caretRect(atUTF16Offset: editorRange.range.location, containerWidth: containerWidth) ?? .zero
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let pos = position as? EditorTextPosition else { return .zero }
        return controller.layout.caretRect(atUTF16Offset: pos.offset, containerWidth: containerWidth) ?? .zero
    }

    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        EditorTextPosition(offset: controller.hitTestOffset(at: point, containerWidth: containerWidth))
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
        let end = min(offset + 1, controller.document.length)
        return EditorTextRange(range: NSRange(location: offset, length: max(0, end - offset)))
    }

    // MARK: - Drag / Drop

    public func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let text = controller.text(in: controller.selectedRanges)
        guard !text.isEmpty else { return [] }
        let provider = NSItemProvider(object: text as NSString)
        return [UIDragItem(itemProvider: provider)]
    }

    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: ["public.plain-text", "public.utf8-plain-text"])
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let self, let text = items.first as? String else { return }
            let point = session.location(in: self)
            let offset = self.controller.hitTestOffset(at: point, containerWidth: self.containerWidth)
            self.controller.setSelectedRange(NSRange(location: offset, length: 0))
            self.controller.insertText(text)
            self.onTextChange?(self.controller.text)
            self.relayout()
        }
    }

    // MARK: - Accessibility

    open override var accessibilityLabel: String? {
        get { "Code editor" }
        set {}
    }

    open override var accessibilityValue: String? {
        get { controller.text }
        set {}
    }

    open override var accessibilityAttributedValue: NSAttributedString? {
        get { NSAttributedString(string: controller.text) }
        set {}
    }
}

@MainActor
final class EditorTextPosition: UITextPosition {
    let offset: Int
    init(offset: Int) { self.offset = offset }
}

@MainActor
final class EditorTextRange: UITextRange {
    let range: NSRange
    init(range: NSRange) { self.range = range }
    override var start: UITextPosition { EditorTextPosition(offset: range.location) }
    override var end: UITextPosition { EditorTextPosition(offset: range.location + range.length) }
    override var isEmpty: Bool { range.length == 0 }
}
#endif
