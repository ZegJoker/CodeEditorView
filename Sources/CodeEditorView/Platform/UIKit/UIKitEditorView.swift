#if canImport(UIKit) && !os(macOS)
    import UIKit
    import SwiftUI
    import CoreGraphics
    import CoreText
    import CodeEditorCore
    import CodeEditorCommands

    /// UIKit host view for ``EditorController`` with `UITextInput` and accessibility.
    open class UIKitEditorView: UIView, UITextInput, UIKeyInput, UIDragInteractionDelegate, UIDropInteractionDelegate {
        public let controller: EditorController

        private let blink = CursorBlinkController()
        private var containerWidth: CGFloat = 0
        private var inputDelegateStorage: UITextInputDelegate?
        private var tokenizerStorage: UITextInputTokenizer!
        private var selectionAnchor: Int?
        /// UTF-16 range of the active IME composition, or `NSNotFound` when none.
        private var markedRangeStorage = NSRange(location: NSNotFound, length: 0)

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

        public var markedTextRange: UITextRange? {
            guard markedRangeStorage.location != NSNotFound else { return nil }
            return EditorTextRange(range: markedRangeStorage)
        }
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
            backgroundColor =
                controller.configuration.appearance.useThemeBackground
                ? controller.configuration.theme.background
                : .systemBackground
            isMultipleTouchEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .updatesFrequently
            tokenizerStorage = UITextInputStringTokenizer(textInput: self)

            blink.onChange = { [weak self] _ in self?.setNeedsDisplay() }
            controller.emphasis.onChange = { [weak self] in self?.setNeedsDisplay() }
            controller.onNeedsDisplay = { [weak self] in
                self?.scrollToSelectionIfNeeded()
                self?.setNeedsDisplay()
            }
            controller.onRequestScrollToSelection = { [weak self] in
                self?.scrollToSelectionIfNeeded()
                self?.setNeedsDisplay()
            }

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            addGestureRecognizer(singleTap)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            singleTap.require(toFail: doubleTap)
            addGestureRecognizer(doubleTap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            addGestureRecognizer(pan)
            // Long-press → jump to definition (iOS equivalent of ⌘-click).
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressJump(_:)))
            longPress.minimumPressDuration = 0.55
            addGestureRecognizer(longPress)

            let drag = UIDragInteraction(delegate: self)
            addInteraction(drag)
            let drop = UIDropInteraction(delegate: self)
            addInteraction(drop)

            controller.onJumpFailed = { [weak self] in
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.warning)
                self?.setNeedsDisplay()
            }
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
            var didInvalidate = false
            if abs(containerWidth - layoutWidth) > 0.5, controller.configuration.wrapLines {
                controller.layout.invalidateAll()
                didInvalidate = true
            }
            containerWidth = layoutWidth
            if didInvalidate, !controller.foldModel.collapsedFolds.isEmpty {
                controller.syncFoldPlaceholdersAndHeights()
            }
            _ = controller.layoutViewport(visibleRect: bounds, containerWidth: layoutWidth)
            invalidateIntrinsicContentSize()
            scrollToSelectionIfNeeded()
            setNeedsDisplay()
        }

        private func scrollToSelectionIfNeeded() {
            guard let target = controller.scrollTarget else { return }
            controller.consumeScrollTarget()
            // Scroll the enclosing UIScrollView (chrome) so the caret is visible.
            if let scroll = enclosingScrollView {
                scroll.scrollRectToVisible(convert(target, to: scroll), animated: true)
            }
        }

        private var enclosingScrollView: UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let scroll = cur as? UIScrollView { return scroll }
                v = cur.superview
            }
            return nil
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

            // Trailing inline message chips (mchakravarty MessageInlineView style).
            if !controller.annotationsByLine.isEmpty {
                AnnotationRenderer.draw(
                    annotationsByLine: controller.annotationsByLine,
                    lineIndex: controller.layout.lineIndex,
                    textLeading: controller.layout.edgeInsets.leading,
                    contentWidth: max(width, bounds.width),
                    visibleRect: rect.union(bounds),
                    excludingLine: annotationPopupLine,
                    in: context
                )
            }

            if controller.configuration.showInvisibleCharacters,
                let delegate = controller.invisibleCharactersDelegate
            {
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
                let visibleFolds: [FoldRange]
                if controller.configuration.peripherals.showFoldingRibbon {
                    if let first = controller.layout.lineIndex.line(atY: visible.minY),
                        let last = controller.layout.lineIndex.line(atY: visible.maxY)
                    {
                        let start = first.utf16Offset
                        let end = last.utf16Offset + last.metrics.utf16Length
                        visibleFolds = controller.folds(in: NSRange(location: start, length: max(0, end - start)))
                    } else {
                        visibleFolds = controller.foldModel.foldCache.allFolds
                    }
                } else {
                    visibleFolds = []
                }
                GutterRenderer.draw(
                    model: model,
                    lineIndex: controller.layout.lineIndex,
                    visibleRect: visible,
                    selectedLineIndices: selectedLines,
                    textColor: theme.gutterText.cgColor,
                    selectedTextColor: theme.text.color.cgColor,
                    backgroundColor: theme.gutterBackground.cgColor,
                    selectedLineColor: theme.lineHighlight.cgColor,
                    folds: visibleFolds,
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

            // Dismiss completion / jump popover when tapping the document.
            if controller.completionsVisible {
                controller.hideCompletions()
            }

            // Trailing message chip tap → unfold full popup.
            if !controller.annotationsByLine.isEmpty,
                let lineIdx = AnnotationRenderer.hitTestLine(
                    at: point,
                    annotationsByLine: controller.annotationsByLine,
                    lineIndex: controller.layout.lineIndex,
                    textLeading: controller.layout.edgeInsets.leading,
                    contentWidth: max(containerWidth, bounds.width)
                ),
                let anns = controller.annotationsByLine[lineIdx], !anns.isEmpty
            {
                presentAnnotationAlert(annotations: anns)
                return
            }

            if annotationPopupHost != nil {
                dismissAnnotationPopup()
            }

            if controller.configuration.peripherals.showGutter,
                controller.configuration.peripherals.showFoldingRibbon
            {
                let model = controller.makeGutterModel()
                if point.x >= model.foldingRibbonMinX, point.x <= model.width,
                    let line = controller.layout.lineIndex.line(atY: point.y),
                    line.metrics.height >= 0.5
                {
                    controller.toggleFold(atLine: line.index)
                    relayout()
                    setNeedsDisplay()
                    return
                }
            }

            if controller.configuration.peripherals.showFoldingRibbon,
                let placeholder = controller.layout.foldPlaceholder(
                    at: point,
                    containerWidth: max(containerWidth, 1)
                )
            {
                controller.handleFoldPlaceholderClick(placeholder.fold)
                relayout()
                setNeedsDisplay()
                return
            }
            controller.clearFoldPlaceholderSelection()

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

        /// Floating expanded message popup (mchakravarty style — not a system sheet when possible).
        private var annotationPopupHost: UIView?
        private var annotationPopupLine: Int?

        private func presentAnnotationAlert(annotations: [LineAnnotation]) {
            let lineIdx = annotations.first?.line
            // Toggle same line.
            if let lineIdx, annotationPopupLine == lineIdx {
                dismissAnnotationPopup()
                return
            }
            dismissAnnotationPopup()

            let host = UIHostingController(rootView: AnnotationPopupView(annotations: annotations))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(host.view)
            annotationPopupHost = host.view
            annotationPopupLine = lineIdx

            if let lineIdx, let line = controller.layout.lineIndex.line(atIndex: lineIdx) {
                let size = host.sizeThatFits(in: CGSize(width: 300, height: UIView.layoutFittingCompressedSize.height))
                let width = min(320, max(180, size.width.isFinite ? size.width : 288))
                var height = size.height.isFinite ? size.height : 48
                if height < 24 || height > 480 {
                    height = min(480, max(36, CGFloat(annotations.count) * 44))
                }
                let x = max(8, bounds.width - width - AnnotationRenderer.popupRightSideOffset)
                let y = line.yOffset + line.metrics.height + 2
                host.view.frame = CGRect(x: x, y: y, width: width, height: height)
            }

            if let first = annotations.first,
                let line = controller.layout.lineIndex.line(atIndex: first.line)
            {
                let offset = min(line.utf16Offset + first.column, controller.document.length)
                controller.setSelectedRange(NSRange(location: offset, length: 0))
                onSelectionChange?(controller.selectedRange)
                scrollToSelectionIfNeeded()
            }
            setNeedsDisplay()
        }

        private func dismissAnnotationPopup() {
            annotationPopupHost?.removeFromSuperview()
            annotationPopupHost = nil
            annotationPopupLine = nil
            setNeedsDisplay()
        }

        @objc private func handleLongPressJump(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began else { return }
            guard controller.jumpToDefinitionDelegate != nil else { return }
            _ = becomeFirstResponder()
            let point = gesture.location(in: self)
            let offset = controller.hitTestOffset(at: point, containerWidth: max(containerWidth, 1))
            if let range = JumpToDefinitionModel.findDefinitionRange(at: offset, controller: controller) {
                controller.jumpHover(atUTF16Offset: offset)
                controller.performJumpToDefinition(at: range)
            } else {
                controller.notifyJumpFailed()
            }
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
                UIKeyCommand(
                    input: UIKeyCommand.inputUpArrow, modifierFlags: .alternate, action: #selector(handleMoveLinesUp)),
                UIKeyCommand(
                    input: UIKeyCommand.inputDownArrow, modifierFlags: .alternate,
                    action: #selector(handleMoveLinesDown)),
                UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(handleToggleCompletions)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
            ]
            if controller.completionsVisible {
                commands.append(contentsOf: [
                    UIKeyCommand(
                        input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleCompletionUp)),
                    UIKeyCommand(
                        input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleCompletionDown)),
                    UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(handleCompletionApply)),
                ])
            }
            return commands
        }

        @objc private func handleToggleCompletions() {
            runCommand(BuiltInCommandID.completionShow)
            setNeedsDisplay()
        }

        @objc private func handleEscape() {
            runCommand(BuiltInCommandID.cancel)
            setNeedsDisplay()
        }

        @objc private func handleCompletionUp() {
            runCommand(BuiltInCommandID.completionUp)
            setNeedsDisplay()
        }

        @objc private func handleCompletionDown() {
            runCommand(BuiltInCommandID.completionDown)
            setNeedsDisplay()
        }

        @objc private func handleCompletionApply() {
            runCommand(BuiltInCommandID.completionApply)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleBacktab() {
            runCommand(BuiltInCommandID.insertBacktab)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleIndent() {
            runCommand(BuiltInCommandID.indent)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleOutdent() {
            runCommand(BuiltInCommandID.outdent)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleMoveLinesUp() {
            runCommand(BuiltInCommandID.moveLinesUp)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleMoveLinesDown() {
            runCommand(BuiltInCommandID.moveLinesDown)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        @objc private func handleToggleComment() {
            runCommand(BuiltInCommandID.toggleLineComment)
            onTextChange?(controller.text)
            onSelectionChange?(controller.selectedRange)
            relayout()
        }

        /// Input-path command execution fails closed into the diagnostic channel (UI-N07).
        private func runCommand(_ id: CommandID) {
            let snapshot = controller.selectedRanges
            do {
                try controller.executeCommand(id)
            } catch {
                controller.diagnosticChannel.reportCommandFailure(
                    error,
                    operation: id.rawValue,
                    selectionSnapshot: snapshot
                )
                // Restore selection if the failed op desynchronized it.
                controller.setSelectedRanges(snapshot)
            }
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
            inputDelegate?.textWillChange(self)
            let text = markedText ?? ""
            // UI-002 / UI-N06: provisional composition via MarkedTextSession (no undo registration).
            let replace =
                markedRangeStorage.location != NSNotFound
                ? markedRangeStorage
                : controller.selectedRange
            if !controller.isComposingMarkedText {
                controller.beginMarkedTextComposition(replacing: replace)
            }
            controller.applyMarkedText(text, selectedRangeInMarked: selectedRange, replaceRange: replace)
            if text.isEmpty {
                // Empty marked text cancels composition and restores pre-composition snapshot.
                controller.cancelMarkedTextComposition()
                markedRangeStorage = NSRange(location: NSNotFound, length: 0)
            } else {
                markedRangeStorage = controller.markedTextSession.range
            }
            inputDelegate?.textDidChange(self)
            onTextChange?(controller.text)
            setNeedsDisplay()
        }

        public func unmarkText() {
            // Commit composition with a single undo boundary (UI-N06).
            controller.commitMarkedTextComposition()
            markedRangeStorage = NSRange(location: NSNotFound, length: 0)
        }

        public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
            guard let from = fromPosition as? EditorTextPosition,
                let to = toPosition as? EditorTextPosition
            else { return nil }
            let text = controller.document.fullString
            let a = NativeInputPositions.clampedGraphemePosition(utf16Offset: from.offset, in: text)
            let b = NativeInputPositions.clampedGraphemePosition(utf16Offset: to.offset, in: text)
            let location = min(a, b)
            let range = NativeInputPositions.clampedGraphemeRange(
                NSRange(location: location, length: abs(a - b)),
                in: text
            )
            return EditorTextRange(range: range)
        }

        public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
            guard let pos = position as? EditorTextPosition else { return nil }
            // Grapheme-valid positions only (UI-N02) — never mid-cluster UTF-16 units.
            let text = controller.document.fullString
            var utf16 = NativeInputPositions.clampedGraphemePosition(utf16Offset: pos.offset, in: text)
            let steps = abs(offset)
            do {
                if offset >= 0 {
                    for _ in 0..<steps {
                        utf16 = try TextOffsetSemantics.graphemeBoundaryAfter(utf16Offset: utf16, in: text)
                    }
                } else {
                    for _ in 0..<steps {
                        utf16 = try TextOffsetSemantics.graphemeBoundaryBefore(utf16Offset: utf16, in: text)
                    }
                }
            } catch {
                controller.diagnosticChannel.reportInputFailure(error, operation: "position(from:offset:)")
                utf16 = NativeInputPositions.clampedGraphemePosition(
                    utf16Offset: min(max(0, pos.offset + offset), controller.document.length),
                    in: text
                )
            }
            return EditorTextPosition(offset: utf16)
        }

        public func position(
            from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
        ) -> UITextPosition? {
            guard let pos = position as? EditorTextPosition else { return nil }
            // Grapheme-aware left/right; vertical via EditorController.visualCaretMove → engine (UI-N01).
            var utf16 = NativeInputPositions.clampedGraphemePosition(
                utf16Offset: pos.offset,
                in: controller.document.fullString
            )
            let visual: VisualDirection
            switch direction {
            case .left: visual = .left
            case .right: visual = .right
            case .up: visual = .up
            case .down: visual = .down
            @unknown default: visual = .right
            }
            let width = containerWidth > 0 ? containerWidth : max(bounds.width, 1)
            var preferred = controller.selection.primarySelection.preferredX
            for _ in 0..<max(0, offset) {
                let moved = controller.visualCaretMove(
                    from: utf16,
                    direction: visual,
                    preferredX: preferred,
                    containerWidth: width
                )
                utf16 = moved.position.utf16Offset
                preferred = moved.preferredX
            }
            return EditorTextPosition(offset: utf16)
        }

        public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
            guard let a = position as? EditorTextPosition, let b = other as? EditorTextPosition else {
                return .orderedSame
            }
            if a.offset < b.offset { return .orderedAscending }
            if a.offset > b.offset { return .orderedDescending }
            return .orderedSame
        }

        public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
            guard let a = from as? EditorTextPosition, let b = toPosition as? EditorTextPosition else { return 0 }
            return b.offset - a.offset
        }

        public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition?
        {
            guard let editorRange = range as? EditorTextRange else { return nil }
            switch direction {
            case .left, .up: return EditorTextPosition(offset: editorRange.range.location)
            case .right, .down: return EditorTextPosition(offset: editorRange.range.location + editorRange.range.length)
            @unknown default: return EditorTextPosition(offset: editorRange.range.location)
            }
        }

        public func characterRange(
            byExtending position: UITextPosition, in direction: UITextLayoutDirection
        ) -> UITextRange? {
            guard let pos = position as? EditorTextPosition else { return nil }
            let next = self.position(from: pos, in: direction, offset: 1) as? EditorTextPosition
            let end = next?.offset ?? pos.offset
            return EditorTextRange(range: NSRange(location: min(pos.offset, end), length: abs(pos.offset - end)))
        }

        public func baseWritingDirection(
            for position: UITextPosition, in direction: UITextStorageDirection
        ) -> NSWritingDirection {
            // Platform BiDi + stored overrides (UI-N04) — not a first-char-only heuristic.
            _ = direction
            guard let pos = position as? EditorTextPosition else { return .leftToRight }
            let text = controller.document.fullString
            let resolved = controller.writingDirectionModel.resolvedDirection(at: pos.offset, in: text)
            return resolved.nsWritingDirection
        }

        public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
            // Persist override — not a no-op (UI-N04).
            guard let editorRange = range as? EditorTextRange else { return }
            let dir = WritingDirectionModel.Direction(ns: writingDirection)
            controller.writingDirectionModel.setBaseWritingDirection(dir, for: editorRange.range)
            // Also stamp paragraph writingDirection attribute for attributedSubstring clients.
            let attrDir: NSWritingDirection = writingDirection == .rightToLeft ? .rightToLeft : .leftToRight
            controller.document.setAttributes(
                [.writingDirection: [attrDir.rawValue as NSNumber]],
                range: editorRange.range
            )
            setNeedsDisplay()
        }

        public func firstRect(for range: UITextRange) -> CGRect {
            guard let editorRange = range as? EditorTextRange else { return .zero }
            let width = containerWidth > 0 ? containerWidth : max(bounds.width, 1)
            let snapshot = controller.layout.makeEditorLayoutSnapshot(
                containerWidth: width,
                documentText: controller.document.fullString
            )
            return NativeInputContracts.firstRect(for: editorRange.range, layout: snapshot).rect
        }

        public func caretRect(for position: UITextPosition) -> CGRect {
            guard let pos = position as? EditorTextPosition else { return .zero }
            let text = controller.document.fullString
            let snapped = NativeInputPositions.clampedGraphemePosition(utf16Offset: pos.offset, in: text)
            return controller.layout.caretRect(atUTF16Offset: snapped, containerWidth: containerWidth) ?? .zero
        }

        public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
            guard let editorRange = range as? EditorTextRange else { return [] }
            // Fragment-based geometry — O(fragments), not O(UTF-16) (UI-N03).
            let width = containerWidth > 0 ? containerWidth : max(bounds.width, 1)
            let snapshot = controller.layout.makeEditorLayoutSnapshot(
                containerWidth: width,
                documentText: controller.document.fullString
            )
            let visible = bounds
            let frags = SelectionGeometry.selectionRects(
                for: editorRange.range,
                layout: snapshot,
                visibleRect: visible
            )
            return frags.map {
                EditorSelectionRect(
                    rect: $0.rect,
                    containsStart: $0.containsStart,
                    containsEnd: $0.containsEnd,
                    writingDirectionRTL: $0.writingDirectionRTL
                )
            }
        }

        public func closestPosition(to point: CGPoint) -> UITextPosition? {
            let raw = controller.hitTestOffset(at: point, containerWidth: containerWidth)
            let snapped = NativeInputPositions.clampedGraphemePosition(
                utf16Offset: raw,
                in: controller.document.fullString
            )
            return EditorTextPosition(offset: snapped)
        }

        public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
            guard let editorRange = range as? EditorTextRange,
                let pos = closestPosition(to: point) as? EditorTextPosition
            else { return nil }
            let text = controller.document.fullString
            let lo = NativeInputPositions.clampedGraphemePosition(
                utf16Offset: editorRange.range.location, in: text
            )
            let hi = NativeInputPositions.clampedGraphemePosition(
                utf16Offset: editorRange.range.location + editorRange.range.length, in: text
            )
            let clamped = min(max(pos.offset, lo), hi)
            return EditorTextPosition(offset: clamped)
        }

        public func characterRange(at point: CGPoint) -> UITextRange? {
            let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)
            let text = controller.document.fullString
            let start = NativeInputPositions.clampedGraphemePosition(utf16Offset: offset, in: text)
            let end: Int
            do {
                end = try TextOffsetSemantics.graphemeBoundaryAfter(utf16Offset: start, in: text)
            } catch {
                controller.diagnosticChannel.reportInputFailure(error, operation: "characterRange(at:)")
                end = min(start + 1, controller.document.length)
            }
            return EditorTextRange(
                range: NativeInputPositions.clampedGraphemeRange(
                    NSRange(location: start, length: max(0, end - start)),
                    in: text
                )
            )
        }

        // MARK: - Drag / Drop

        public func dragInteraction(
            _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            let text = controller.text(in: controller.selectedRanges)
            guard !text.isEmpty else { return [] }
            let provider = NSItemProvider(object: text as NSString)
            return [UIDragItem(itemProvider: provider)]
        }

        public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: ["public.plain-text", "public.utf8-plain-text"])
        }

        public func dropInteraction(
            _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
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
            get { controller.accessibilityLabelText }
            set { _ = newValue }
        }

        open override var accessibilityValue: String? {
            get { controller.accessibilityValueText }
            set { _ = newValue }
        }

        open override var accessibilityHint: String? {
            get {
                var parts: [String] = []
                if let multi = EditorAccessibility.multiCursorSummary(rangeCount: controller.selectedRanges.count) {
                    parts.append(multi)
                }
                let summary = controller.accessibilitySemanticSummary.announcement
                if !summary.isEmpty { parts.append(summary) }
                return parts.isEmpty ? nil : parts.joined(separator: ". ")
            }
            set { _ = newValue }
        }

        open override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            get {
                var actions: [UIAccessibilityCustomAction] = []
                if controller.jumpToDefinitionDelegate != nil {
                    actions.append(
                        UIAccessibilityCustomAction(name: "Jump to Definition") { [weak self] _ in
                            self?.controller.jumpToDefinition()
                            return true
                        }
                    )
                }
                actions.append(
                    UIAccessibilityCustomAction(name: "Find Next") { [weak self] _ in
                        self?.controller.findNext()
                        return true
                    }
                )
                return actions.isEmpty ? super.accessibilityCustomActions : actions
            }
            set {
                super.accessibilityCustomActions = newValue
            }
        }

        /// Semantic rotors wired to live editor state (UI-N10).
        open override var accessibilityCustomRotors: [UIAccessibilityCustomRotor]? {
            get {
                let items = controller.accessibilityCustomRotorDescriptors
                guard !items.isEmpty else { return super.accessibilityCustomRotors }
                return items.map { item in
                    UIAccessibilityCustomRotor(name: "\(item.label) (\(item.count))") { [weak self] predicate in
                        guard let self else { return nil }
                        let target = self.rotorTargetOffset(for: item)
                        if let target {
                            self.controller.setSelectedRange(NSRange(location: target, length: 0))
                        }
                        _ = predicate
                        return UIAccessibilityCustomRotorItemResult(targetElement: self, targetRange: nil)
                    }
                }
            }
            set { super.accessibilityCustomRotors = newValue }
        }

        private func rotorTargetOffset(for item: EditorAccessibility.RotorItem) -> Int? {
            let label = item.label.lowercased()
            if label.contains("breakpoint"), let first = controller.accessibilityBreakpointOffsets.first {
                return first
            }
            if label.contains("search"), let match = controller.findSession.matches.first {
                return match.location
            }
            if label.contains("diagnostic"), let ann = controller.annotations.first {
                return ann.range?.location
                    ?? controller.layout.lineIndex.line(atIndex: ann.line)?.utf16Offset
            }
            return controller.selectedRange.location
        }

        /// Virtualized accessibility value: selection summary, not the entire document (a11y scale).
        open override var accessibilityAttributedValue: NSAttributedString? {
            get {
                let summary = controller.accessibilityValueText
                return NSAttributedString(string: summary)
            }
            set {}
        }
    }

    @MainActor
    final class EditorTextPosition: UITextPosition {
        let offset: Int
        init(offset: Int) { self.offset = offset }
    }

    /// Concrete selection rect for UITextInput selection geometry (UI-001 / UI-N03).
    final class EditorSelectionRect: UITextSelectionRect {
        private let _rect: CGRect
        private let _containsStart: Bool
        private let _containsEnd: Bool
        private let _rtl: Bool

        init(rect: CGRect, containsStart: Bool, containsEnd: Bool, writingDirectionRTL: Bool = false) {
            self._rect = rect
            self._containsStart = containsStart
            self._containsEnd = containsEnd
            self._rtl = writingDirectionRTL
            super.init()
        }

        override var rect: CGRect { _rect }
        override var writingDirection: NSWritingDirection { _rtl ? .rightToLeft : .leftToRight }
        override var containsStart: Bool { _containsStart }
        override var containsEnd: Bool { _containsEnd }
        override var isVertical: Bool { false }
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
