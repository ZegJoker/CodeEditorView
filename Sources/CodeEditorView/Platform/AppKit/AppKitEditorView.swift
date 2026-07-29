#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import CoreText
import SwiftUI

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
    private var observedClipView: NSClipView?
    /// Guards against setFrameSize → frameDidChange → relayout feedback (UI freeze).
    private var isRelayouting = false
    /// Last content size applied to the document view (hysteresis against sub-pixel thrash).
    private var lastAppliedContentSize: CGSize = .zero
    /// Local tracking for ⌘-hover jump-to-definition.
    private var jumpTrackingArea: NSTrackingArea?
    /// After ⌘-click jump, ignore mouseDragged until mouseUp (avoids selecting from old caret → click).
    private var suppressDragSelection = false
    /// Expanded message popup (mchakravarty style — floating SwiftUI subview, not NSPopover).
    private var annotationPopupContainer: AnnotationPopupContainer?
    private var annotationPopupLine: Int? {
        annotationPopupContainer?.lineIndex
    }

    public var onTextChange: ((String) -> Void)?
    public var onSelectionChange: ((NSRange) -> Void)?
    /// Fired just before this view becomes first responder (e.g. user clicked the document).
    public var onWillBecomeFirstResponder: (() -> Void)?

    public init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        // Avoid frame notifications for self: we resize the document view inside relayout.
        // Observing our own frame changes caused setFrameSize → frameDidChange → relayout loops
        // (especially on language switch / wrap toggle) that freeze the app.
        postsFrameChangedNotifications = false
        postsBoundsChangedNotifications = true
        canDrawConcurrently = false
        registerForDraggedTypes([.string])

        blink.onChange = { [weak self] _ in
            self?.needsDisplay = true
        }
        controller.emphasis.onChange = { [weak self] in
            self?.needsDisplay = true
        }
        controller.onNeedsDisplay = { [weak self] in
            self?.scrollToSelectionIfNeeded()
            self?.needsDisplay = true
        }
        controller.onJumpFailed = { [weak self] in
            NSSound.beep()
            self?.needsDisplay = true
        }
        controller.onRequestScrollToSelection = { [weak self] in
            self?.scrollToSelectionIfNeeded()
            self?.needsDisplay = true
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        dragScrollTask?.cancel()
    }

    open override var acceptsFirstResponder: Bool {
        controller.configuration.isSelectable || controller.configuration.isEditable
    }
    open override var isFlipped: Bool { true }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            controller.notifyDidAppear()
            installClipViewObserver()
            // Ensure a command-line / SPM-launched host can type into the editor.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(self)
            }
        } else {
            controller.notifyDidDisappear()
            removeClipViewObserver()
        }
        relayout()
    }

    open override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installClipViewObserver()
        relayout()
    }

    open override func layout() {
        super.layout()
        // Skip if we're already driving layout from relayout (setFrameSize → layout → …).
        guard !isRelayouting else { return }
        relayout()
    }

    @objc private func clipViewBoundsDidChange(_ note: Notification) {
        // Clip bounds change when the window resizes or scrollers appear — re-wrap.
        guard !isRelayouting else { return }
        relayout()
    }

    private func installClipViewObserver() {
        removeClipViewObserver()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        observedClipView = clip
    }

    private func removeClipViewObserver() {
        if let clip = observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }
        observedClipView = nil
    }

    /// Visible content width of the enclosing scroll view (fallback to own bounds).
    /// Uses the clip view bounds only — never the document view width — so wrap tracks the window.
    private var clipWidth: CGFloat {
        if let scroll = enclosingScrollView {
            // Prefer contentView.bounds (stable clip width). Avoid documentVisibleRect while
            // the document is mid-resize; it can echo the document width and defeat wrapping.
            let content = scroll.contentView.bounds.width
            if content > 1 { return content }
            let visible = scroll.documentVisibleRect.width
            if visible > 1 { return visible }
        }
        if let w = superview?.bounds.width, w > 1 {
            return w
        }
        return max(bounds.width, 1)
    }

    public func relayout() {
        guard !isRelayouting else { return }
        isRelayouting = true
        defer { isRelayouting = false }

        // Keep layout engine wrap flag in sync even if configuration was assigned without didSet path.
        let wrap = controller.configuration.wrapLines
        if controller.layout.wrapLines != wrap {
            controller.layout.wrapLines = wrap
        }

        let clip = max(clipWidth, 1)

        // Autoresizing must match wrap mode: track clip width when wrapping; free width otherwise.
        autoresizingMask = wrap ? [.width] : []

        // When wrapping, layout width is always the visible clip — never the (possibly stale) document width.
        let layoutWidth: CGFloat = wrap ? clip : max(clip, bounds.width, 1)
        var didInvalidate = false
        if abs(containerWidth - layoutWidth) > 0.5 {
            controller.layout.invalidateAll()
            didInvalidate = true
        }
        containerWidth = layoutWidth

        // After a full rebuild (resize/wrap), re-apply fold collapse so line numbers
        // and heights stay in sync with collapsed folds.
        if didInvalidate, !controller.foldModel.collapsedFolds.isEmpty {
            controller.syncFoldPlaceholdersAndHeights()
        }

        let visible = visibleRect.isEmpty
            ? CGRect(x: 0, y: 0, width: layoutWidth, height: max(bounds.height, 1))
            : visibleRect
        let snapshot = controller.layoutViewport(visibleRect: visible, containerWidth: layoutWidth)
        let size = snapshot.contentSize

        // Pin document width to the clip while wrapping so NSScrollView cannot grow horizontally.
        let width: CGFloat = wrap ? clip : max(clip, size.width, 1)
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(size.height, clipHeight, 1)
        let newSize = CGSize(width: width, height: height)
        // Hysteresis: ignore sub-pixel / 1pt thrash that causes layout → setFrameSize loops (freezes).
        let widthDelta = abs(lastAppliedContentSize.width - newSize.width)
        let heightDelta = abs(lastAppliedContentSize.height - newSize.height)
        if widthDelta > 1.0 || heightDelta > 1.0 {
            lastAppliedContentSize = newSize
            if abs(frame.height - height) > 1.0 || abs(frame.width - width) > 1.0 {
                setFrameSize(NSSize(width: width, height: height))
            }
        }

        if let scroll = enclosingScrollView {
            scroll.hasHorizontalScroller = !wrap
            scroll.horizontalScrollElasticity = wrap ? .none : .allowed
        }

        scrollToSelectionIfNeeded()
        layoutAnnotationPopup()
        needsDisplay = true
    }

    private func scrollToSelectionIfNeeded() {
        guard let target = controller.scrollTarget else { return }
        // Consume first so a clip-bounds → relayout loop cannot keep re-applying
        // the target and pin the scroll position to the caret.
        controller.consumeScrollTarget()
        scrollToVisible(target)
    }

    private func contentSizeHeight() -> CGFloat {
        max(controller.contentSize.height, bounds.height)
    }

    // MARK: - Drawing

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let visible = dirtyRect.union(visibleRect)
        let width = containerWidth > 0 ? containerWidth : clipWidth
        let snapshot = controller.layoutViewport(visibleRect: visible, containerWidth: width)
        let theme = controller.configuration.theme
        let gutterWidth = controller.gutterWidth
        let selectedLines = controller.selectedLineIndices

        if controller.configuration.appearance.useThemeBackground {
            context.setFillColor(theme.background.cgColor)
            context.fill(visible)
        }

        // Current line highlight (behind text, right of gutter).
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
            let guideColor = theme.reformattingGuide.cgColor
            // Full document bounds so the guide is not clipped to a partial dirty rect.
            let guideRect = CGRect(
                x: 0,
                y: 0,
                width: max(bounds.width, width, clipWidth),
                height: max(contentSizeHeight(), bounds.height, 1)
            )
            ChromeRenderer.drawReformattingGuide(
                column: controller.configuration.behavior.reformatAtColumn,
                characterWidth: max(controller.configuration.characterWidth, 1),
                textLeadingInset: controller.layout.edgeInsets.leading,
                visibleRect: guideRect,
                color: guideColor,
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
        // Hide the chip for the line that is currently expanded to the full popup.
        if !controller.annotationsByLine.isEmpty {
            AnnotationRenderer.draw(
                annotationsByLine: controller.annotationsByLine,
                lineIndex: controller.layout.lineIndex,
                textLeading: controller.layout.edgeInsets.leading,
                contentWidth: max(width, bounds.width),
                visibleRect: visible,
                excludingLine: annotationPopupLine,
                in: context
            )
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

        if controller.configuration.peripherals.showGutter {
            let model = controller.makeGutterModel()
            let visibleFolds: [FoldRange]
            if controller.configuration.peripherals.showFoldingRibbon {
                let yRange = visible
                // Query folds covering the visible vertical span via first/last visible lines.
                if let first = controller.layout.lineIndex.line(atY: yRange.minY),
                   let last = controller.layout.lineIndex.line(atY: yRange.maxY) {
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
        onWillBecomeFirstResponder?()
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

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let jumpTrackingArea {
            removeTrackingArea(jumpTrackingArea)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .inVisibleRect,
            .cursorUpdate,
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        jumpTrackingArea = area
    }

    open override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), controller.jumpToDefinitionDelegate != nil {
            let point = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let offset = controller.hitTestOffset(at: point, containerWidth: max(containerWidth, 1))
            controller.jumpHover(atUTF16Offset: offset)
            updateJumpCursor()
        } else {
            controller.cancelJumpHover()
            NSCursor.iBeam.set()
        }
        needsDisplay = true
    }

    open override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), controller.jumpToDefinitionDelegate != nil else {
            if controller.jumpHoveredRange != nil {
                controller.cancelJumpHover()
                NSCursor.iBeam.set()
                needsDisplay = true
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let offset = controller.hitTestOffset(at: point, containerWidth: max(containerWidth, 1))
        controller.jumpHover(atUTF16Offset: offset)
        updateJumpCursor()
        needsDisplay = true
    }

    open override func cursorUpdate(with event: NSEvent) {
        if controller.jumpHoveredRange != nil,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func updateJumpCursor() {
        if controller.jumpHoveredRange != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    open override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        let point = convert(event.locationInWindow, from: nil)

        // Clicks inside the open message popup are handled by the popup (text selection /
        // copy). Do not steal first responder or dismiss.
        if let popup = annotationPopupContainer, popup.frame.contains(point) {
            return
        }

        onWillBecomeFirstResponder?()
        window?.makeFirstResponder(self)

        // Clicking the document dismisses completion / jump-to-definition popovers
        // (the floating panel is a separate window, so its clicks never reach here).
        if controller.completionsVisible {
            controller.hideCompletions()
        }

        // Trailing message chip click → unfold full popup (mchakravarty MessageView toggle).
        // Exclude the line already expanded (its chip is hidden; hit-testing that rect
        // would immediately toggle-dismiss when the user aims near the popup).
        if !controller.annotationsByLine.isEmpty,
           let lineIdx = AnnotationRenderer.hitTestLine(
            at: point,
            annotationsByLine: controller.annotationsByLine,
            lineIndex: controller.layout.lineIndex,
            textLeading: controller.layout.edgeInsets.leading,
            contentWidth: max(containerWidth, bounds.width),
            excludingLine: annotationPopupLine
           ),
           let anns = controller.annotationsByLine[lineIdx], !anns.isEmpty
        {
            // Prevent mouseDragged from selecting from the old caret → chip (end of line).
            suppressDragSelection = true
            columnAnchor = nil
            presentAnnotationPopup(annotations: anns, line: lineIdx)
            return
        }

        // Click elsewhere collapses an open message popup.
        if annotationPopupContainer != nil {
            dismissAnnotationPopup()
        }

        // ⌘-click jump-to-definition when hovering an identifier.
        // Do not place/extend the caret on this gesture — otherwise a tiny drag after
        // ⌘-click selects from the previous caret through the click site.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           controller.jumpToDefinitionDelegate != nil
        {
            let offset = controller.hitTestOffset(at: point, containerWidth: max(containerWidth, 1))
            let range = controller.jumpHoveredRange
                ?? JumpToDefinitionModel.findDefinitionRange(at: offset, controller: controller)
            if let range {
                suppressDragSelection = true
                columnAnchor = nil
                // Keep selection where it is until the user picks a jump target.
                controller.performJumpToDefinition(at: range)
                needsDisplay = true
                return
            }
            // ⌘-click with no identifier: still suppress drag-select from prior caret.
            suppressDragSelection = true
            selectionAnchor = offset
            columnAnchor = nil
            controller.selection.mode = .character
            controller.setSelectedRange(NSRange(location: offset, length: 0))
            blink.reset()
            onSelectionChange?(controller.selectedRange)
            needsDisplay = true
            return
        }

        // Fold ribbon click (trailing strip of the gutter).
        if controller.configuration.peripherals.showGutter,
           controller.configuration.peripherals.showFoldingRibbon {
            let model = controller.makeGutterModel()
            let ribbonMinX = model.foldingRibbonMinX
            let ribbonMaxX = model.width
            if point.x >= ribbonMinX, point.x <= ribbonMaxX,
               let line = controller.layout.lineIndex.line(atY: point.y),
               line.metrics.height >= 0.5 {
                controller.toggleFold(atLine: line.index)
                relayout()
                needsDisplay = true
                return
            }
        }

        // Fold placeholder bubble (Xcode: first click selects, second expands).
        if controller.configuration.peripherals.showFoldingRibbon,
           let placeholder = controller.layout.foldPlaceholder(
            at: point,
            containerWidth: max(containerWidth, 1)
           ) {
            controller.handleFoldPlaceholderClick(placeholder.fold)
            relayout()
            needsDisplay = true
            return
        }

        // Click elsewhere clears placeholder selection.
        controller.clearFoldPlaceholderSelection()

        let offset = controller.hitTestOffset(at: point, containerWidth: containerWidth)

        // Double-click: select word at click point.
        if event.clickCount == 2,
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control) {
            controller.selection.mode = .character
            controller.selectWord(atUTF16Offset: offset)
            selectionAnchor = controller.selectedRange.location
            columnAnchor = nil
            blink.reset()
            onSelectionChange?(controller.selectedRange)
            needsDisplay = true
            return
        }

        // Triple-click: select whole line.
        if event.clickCount >= 3,
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.command) {
            let lineStart = controller.document.findStartOfLine(containing: offset)
            let lineEnd = controller.document.findEndOfLine(containing: offset)
            controller.selection.mode = .character
            controller.setSelectedRange(NSRange(location: lineStart, length: max(0, lineEnd - lineStart)))
            selectionAnchor = lineStart
            columnAnchor = nil
            blink.reset()
            onSelectionChange?(controller.selectedRange)
            needsDisplay = true
            return
        }

        if event.modifierFlags.contains(.option) {
            if event.modifierFlags.contains(.shift) {
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
        // ⌘-click jump / post-jump: do not extend selection from the previous caret.
        if suppressDragSelection
            || event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        {
            return
        }
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
        suppressDragSelection = false
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command), chars == "a" {
            selectAll(nil)
            return
        }
        // Find / replace (⌘F find, ⌘R expand/show replace, ⌥⌘F replace, ⌘G / ⇧⌘G next/prev)
        if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), chars == "f" {
            controller.showFindPanel(mode: .find)
            return
        }
        if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), chars == "r" {
            // When find is already open, expand to replace; otherwise open replace mode.
            controller.showReplacePanel()
            return
        }
        if flags.contains(.command), flags.contains(.option), !flags.contains(.shift), chars == "f" {
            controller.showReplacePanel()
            return
        }
        if flags.contains(.command), !flags.contains(.shift), chars == "g" {
            controller.findNext()
            finishSelection()
            return
        }
        if flags.contains(.command), flags.contains(.shift), chars == "g" {
            controller.findPrevious()
            finishSelection()
            return
        }
        if event.keyCode == 53 { // Escape
            if controller.findSession.isShowing {
                controller.hideFindPanel()
                return
            }
            // CESE: Escape toggles completions when find is closed.
            if controller.completionsVisible {
                controller.hideCompletions()
                return
            }
            if controller.completionDelegate != nil {
                controller.showCompletions()
                return
            }
            controller.collapseCursors()
            onSelectionChange?(controller.selectedRange)
            needsDisplay = true
            return
        }
        // Ctrl-Space: show completions
        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
           chars == " " || event.keyCode == 49 {
            if controller.completionsVisible {
                controller.hideCompletions()
            } else {
                controller.showCompletions()
            }
            return
        }
        // Jump to definition: ⌃⌘J (CESE)
        if flags.contains(.command), flags.contains(.control), !flags.contains(.shift),
           !flags.contains(.option), chars.lowercased() == "j",
           controller.jumpToDefinitionDelegate != nil
        {
            controller.jumpToDefinition()
            finishSelection()
            return
        }
        // Completion list navigation while visible
        if controller.completionsVisible {
            if event.keyCode == 125 { // Down
                controller.moveCompletionSelection(delta: 1)
                return
            }
            if event.keyCode == 126 { // Up
                controller.moveCompletionSelection(delta: -1)
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
                controller.applyCompletionSelection()
                finishEdit()
                return
            }
        }
        // Structure shortcuts
        if flags.contains(.command), chars == "]" {
            controller.indentSelection()
            finishEdit()
            return
        }
        if flags.contains(.command), chars == "[" {
            controller.outdentSelection()
            finishEdit()
            return
        }
        if flags.contains(.command), chars == "/" {
            controller.toggleLineComment()
            finishEdit()
            return
        }
        if flags.contains(.option), event.keyCode == 126 { // Up
            controller.moveSelectedLines(up: true)
            finishEdit()
            return
        }
        if flags.contains(.option), event.keyCode == 125 { // Down
            controller.moveSelectedLines(up: false)
            finishEdit()
            return
        }
        interpretKeyEvents([event])
    }

    open override func insertTab(_ sender: Any?) {
        controller.insertTab()
        finishEdit()
    }

    open override func insertBacktab(_ sender: Any?) {
        controller.insertBacktab()
        finishEdit()
    }

    open override func insertNewline(_ sender: Any?) {
        controller.insertNewline()
        finishEdit()
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

    // MARK: - Annotations (Phase 12)

    /// Unfold the mchakravarty-style message popup for a line.
    ///
    /// Hosts ``AnnotationPopupView`` as a floating subview — right-aligned under the line.
    /// Does **not** move the text caret (avoids selecting from old caret → chip on drag).
    private func presentAnnotationPopup(annotations: [LineAnnotation], line lineIdx: Int) {
        // Replace any existing popup (animated out).
        if annotationPopupContainer != nil {
            dismissAnnotationPopup(animated: false)
        }

        guard controller.layout.lineIndex.line(atIndex: lineIdx) != nil else { return }

        let container = AnnotationPopupContainer(annotations: annotations, lineIndex: lineIdx)
        addSubview(container)
        annotationPopupContainer = container

        let frame = annotationPopupFrame(for: container, line: lineIdx)
        container.animateIn(to: frame)
        needsDisplay = true // hide the chip for this line
    }

    private func dismissAnnotationPopup(animated: Bool = true) {
        guard let container = annotationPopupContainer else { return }
        annotationPopupContainer = nil
        needsDisplay = true // restore chip immediately
        if animated {
            container.animateOut()
        } else {
            container.removeFromSuperview()
        }
    }

    /// Position the expanded popup under the line, offset from the trailing edge
    /// (mchakravarty `popupRightSideOffset` + `popupOffset` below the line).
    private func layoutAnnotationPopup() {
        guard let container = annotationPopupContainer,
              let lineIdx = annotationPopupLine
        else { return }
        let frame = annotationPopupFrame(for: container, line: lineIdx)
        // Keep on-screen without re-playing the intro animation during scroll/relayout.
        container.frame = frame
    }

    private func annotationPopupFrame(for container: AnnotationPopupContainer, line lineIdx: Int) -> CGRect {
        let size = container.measureFittingSize()
        let rightInset = AnnotationRenderer.popupRightSideOffset
        let x = max(controller.layout.edgeInsets.leading, bounds.width - size.width - rightInset)
        let y: CGFloat
        if let line = controller.layout.lineIndex.line(atIndex: lineIdx) {
            // Sit just under the annotated line (flipped coords: larger y is lower).
            y = line.yOffset + line.metrics.height + 2
        } else {
            y = 0
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Accessibility

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    open override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard controller.jumpToDefinitionDelegate != nil else {
            return super.accessibilityCustomActions()
        }
        let jump = NSAccessibilityCustomAction(name: "Jump to Definition") { [weak self] in
            self?.controller.jumpToDefinition()
            return true
        }
        return [jump]
    }
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
