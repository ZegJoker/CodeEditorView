#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics

/// Trailing minimap strip: bubble content, viewport indicator, click/drag to scroll.
///
/// The strip fills the editor height. Bubble content is scaled from the document
/// (may be shorter than the strip). The gray viewport overlay maps the *visible*
/// editor range — it is not stretched to the full strip (CESE-aligned).
final class AppKitMinimapView: NSView {
    weak var controller: EditorController?
    weak var editorScrollView: NSScrollView?

    private let separator = NSView()
    private let contentView = MinimapContentView()
    private let scrollView = NSScrollView()
    private let viewportView = NSView()
    private var pan: NSPanGestureRecognizer?
    private var lastHostWidth: CGFloat = 0
    private var isAttached = false
    /// Avoid re-entrant reload while we scroll the editor clip view.
    private var isUpdatingViewport = false
    /// Avoid layout → reload → inset → layout recursion.
    private var isReloading = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.masksToBounds = true

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = contentView

        contentView.wantsLayer = true

        viewportView.wantsLayer = true
        viewportView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor

        addSubview(separator)
        addSubview(scrollView)
        addSubview(viewportView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scrollView.addGestureRecognizer(click)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        viewportView.addGestureRecognizer(pan)
        self.pan = pan
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(controller: EditorController, editorScrollView: NSScrollView) {
        self.controller = controller
        self.editorScrollView = editorScrollView
        contentView.controller = controller
        guard !isAttached else {
            reload()
            return
        }
        isAttached = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: editorScrollView.contentView
        )
        editorScrollView.contentView.postsBoundsChangedNotifications = true
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if visible { reload() }
    }

    func reload() {
        guard let controller, !isHidden else { return }
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        layoutStripSubviews()

        let hostW = hostWidth()
        if abs(hostW - lastHostWidth) > 0.5 {
            lastHostWidth = hostW
            controller.updateMinimapTrailingInset(hostWidth: max(hostW, 1))
        }

        let theme = controller.configuration.theme
        layer?.backgroundColor = theme.background.cgColor
        let isLight = Self.isLightColor(theme.background)
        separator.layer?.backgroundColor = (isLight ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.12).cgColor
        viewportView.layer?.backgroundColor = (isLight ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.08).cgColor

        let contentH = max(controller.minimapContentHeight(), 1)
        let width = max(scrollView.bounds.width, 1)
        // Document height follows scaled content only — do not inflate to strip height
        // (that desynced the viewport from the bubbles).
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentH)
        contentView.controller = controller
        contentView.needsDisplay = true
        updateViewport()
    }

    private func layoutStripSubviews() {
        let sep = MinimapMetrics.separatorWidth
        let h = max(bounds.height, 0)
        let w = max(bounds.width, 0)
        separator.frame = CGRect(x: 0, y: 0, width: sep, height: h)
        scrollView.frame = CGRect(x: sep, y: 0, width: max(0, w - sep), height: h)
    }

    private func hostWidth() -> CGFloat {
        if let chrome = superview {
            return max(chrome.bounds.width, 1)
        }
        if let editorScroll = editorScrollView {
            return max(editorScroll.bounds.width, 1)
        }
        return max(bounds.width, 1)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !isUpdatingViewport else { return }
        updateViewport()
    }

    /// CESE-aligned viewport: size and Y track the *visible* editor fraction of the
    /// minimap content, not the full strip height.
    private func updateViewport() {
        guard let controller, let editorScroll = editorScrollView else { return }
        isUpdatingViewport = true
        defer { isUpdatingViewport = false }

        let editorH = max(
            controller.layout.lineIndex.height,
            controller.contentSize.height,
            editorScroll.documentView?.frame.height ?? 0,
            1
        )
        let docMiniH = max(controller.minimapContentHeight(), 1)
        let stripH = max(bounds.height, 1)
        let visible = editorScroll.contentView.bounds
        let visibleH = max(visible.height, 1)

        let frame = MinimapGeometry.viewportFrame(
            editorOffsetY: visible.origin.y,
            editorVisibleHeight: visibleH,
            editorHeight: editorH,
            contentHeight: docMiniH,
            stripHeight: stripH
        )
        let scrollFraction = MinimapGeometry.scrollFraction(
            editorOffsetY: visible.origin.y,
            editorHeight: editorH,
            editorVisibleHeight: visibleH
        )

        // When content is taller than the strip, scroll minimap content with the editor.
        if docMiniH > stripH {
            let maxMiniScroll = max(0, docMiniH - stripH)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollFraction * maxMiniScroll))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let width = max(0, bounds.width - MinimapMetrics.separatorWidth)
        viewportView.frame = CGRect(
            x: MinimapMetrics.separatorWidth,
            y: frame.origin.y,
            width: width,
            height: frame.height
        )
    }

    @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
        guard let controller, let editorScroll = editorScrollView else { return }
        let p = sender.location(in: contentView)
        let editorH = max(controller.layout.lineIndex.height, controller.contentSize.height, 1)
        let docMiniH = max(controller.minimapContentHeight(), 1)
        // Clicks map through document content coordinates only.
        let editorY = MinimapGeometry.editorY(
            minimapY: p.y,
            editorHeight: editorH,
            minimapHeight: docMiniH
        )
        let visibleH = editorScroll.contentView.bounds.height
        let maxY = max(0, editorH - visibleH)
        let target = min(maxY, max(0, editorY - visibleH * 0.3))
        isUpdatingViewport = true
        editorScroll.contentView.scroll(to: NSPoint(x: editorScroll.contentView.bounds.origin.x, y: target))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        isUpdatingViewport = false
        updateViewport()
    }

    @objc private func handlePan(_ sender: NSPanGestureRecognizer) {
        guard let controller, let editorScroll = editorScrollView else { return }
        let translation = sender.translation(in: self)
        sender.setTranslation(.zero, in: self)

        let editorH = max(controller.layout.lineIndex.height, controller.contentSize.height, 1)
        let docMiniH = max(controller.minimapContentHeight(), 1)
        let stripH = max(bounds.height, 1)
        let availableH = min(docMiniH, stripH)
        let visibleH = max(editorScroll.contentView.bounds.height, 1)
        let maxEditorScroll = max(0, editorH - visibleH)
        guard maxEditorScroll > 0, availableH > 0 else { return }

        // Dragging the viewport moves scroll fraction along the track.
        let travel = max(MinimapMetrics.lineHeight, availableH - MinimapMetrics.lineHeight)
        let deltaFraction = translation.y / travel
        var y = editorScroll.contentView.bounds.origin.y + deltaFraction * maxEditorScroll
        y = min(maxEditorScroll, max(0, y))

        isUpdatingViewport = true
        editorScroll.contentView.scroll(to: NSPoint(x: editorScroll.contentView.bounds.origin.x, y: y))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        isUpdatingViewport = false
        updateViewport()
    }

    override func layout() {
        super.layout()
        layoutStripSubviews()
        // Do not call reload() from layout — that re-entered via trailing-inset
        // updates and could stack-overflow. Hosts call reload() on content changes.
        if !isHidden, !isReloading {
            updateViewport()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Draws minimap bubbles for the controller snapshot.
final class MinimapContentView: NSView {
    weak var controller: EditorController?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let controller, let context = NSGraphicsContext.current?.cgContext else { return }
        let snapshot = controller.minimapSnapshot(visibleMinimapRect: dirtyRect.insetBy(dx: 0, dy: -20))
        let theme = controller.configuration.theme

        for rect in snapshot.selectionRects {
            context.setFillColor(theme.selection.withAlphaComponent(0.25).cgColor)
            context.fill(rect)
        }

        for line in snapshot.lines {
            let bubbleH = max(1, line.height - 1)
            for bubble in line.bubbles {
                let color = theme.color(for: bubble.capture)
                context.setFillColor(color.cgColor)
                let r = CGRect(
                    x: bubble.minimapX,
                    y: line.y + 0.5,
                    width: bubble.minimapWidth,
                    height: bubbleH
                )
                context.fill(r)
            }
        }
    }

    override var isOpaque: Bool { false }
}

extension AppKitMinimapView {
    fileprivate static func isLightColor(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        let r = rgb.redComponent
        let g = rgb.greenComponent
        let b = rgb.blueComponent
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.5
    }
}
#endif
