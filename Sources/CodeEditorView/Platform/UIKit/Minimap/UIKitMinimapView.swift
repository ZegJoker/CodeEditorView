#if canImport(UIKit) && !os(macOS)
    import UIKit
    import CoreGraphics

    /// Trailing minimap strip for UIKit (parity with AppKit).
    final class UIKitMinimapView: UIView {
        weak var controller: EditorController?
        weak var editorScrollView: UIScrollView?

        private let separator = UIView()
        private let contentView = UIKitMinimapContentView()
        private let scrollView = UIScrollView()
        private let viewportView = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .systemBackground
            separator.backgroundColor = .separator
            viewportView.backgroundColor = UIColor.label.withAlphaComponent(0.08)
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.bounces = false
            scrollView.addSubview(contentView)

            addSubview(separator)
            addSubview(scrollView)
            addSubview(viewportView)

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            scrollView.addGestureRecognizer(tap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            viewportView.addGestureRecognizer(pan)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func attach(controller: EditorController, editorScrollView: UIScrollView) {
            self.controller = controller
            self.editorScrollView = editorScrollView
            contentView.controller = controller
            // Scroll sync is driven from representable/layout reloads (no Combine).
            reload()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let sep = MinimapMetrics.separatorWidth
            separator.frame = CGRect(x: 0, y: 0, width: sep, height: bounds.height)
            scrollView.frame = CGRect(x: sep, y: 0, width: max(0, bounds.width - sep), height: bounds.height)
            reload()
        }

        func setVisible(_ visible: Bool) {
            isHidden = !visible
            if visible { reload() }
        }

        func reload() {
            guard let controller, !isHidden else { return }
            let hostW = superview?.bounds.width ?? bounds.width
            controller.updateMinimapTrailingInset(hostWidth: max(hostW, 1))
            let theme = controller.configuration.theme
            backgroundColor = theme.background
            let contentH = max(controller.minimapContentHeight(), 1)
            let width = max(scrollView.bounds.width, 1)
            contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentH)
            scrollView.contentSize = contentView.frame.size
            contentView.setNeedsDisplay()
            updateViewport()
        }

        private func updateViewport() {
            guard let controller, let editorScroll = editorScrollView else { return }
            let editorH = max(controller.layout.lineIndex.height, controller.contentSize.height, 1)
            let docMiniH = max(controller.minimapContentHeight(), 1)
            let stripH = max(bounds.height, 1)
            let visibleH = max(editorScroll.bounds.height, 1)
            let offsetY = editorScroll.contentOffset.y

            let frame = MinimapGeometry.viewportFrame(
                editorOffsetY: offsetY,
                editorVisibleHeight: visibleH,
                editorHeight: editorH,
                contentHeight: docMiniH,
                stripHeight: stripH
            )
            let scrollFraction = MinimapGeometry.scrollFraction(
                editorOffsetY: offsetY,
                editorHeight: editorH,
                editorVisibleHeight: visibleH
            )

            if docMiniH > stripH {
                let maxMiniScroll = max(0, docMiniH - stripH)
                scrollView.contentOffset = CGPoint(x: 0, y: scrollFraction * maxMiniScroll)
            } else {
                scrollView.contentOffset = .zero
            }

            viewportView.frame = CGRect(
                x: MinimapMetrics.separatorWidth,
                y: frame.origin.y,
                width: max(0, bounds.width - MinimapMetrics.separatorWidth),
                height: frame.height
            )
        }

        @objc private func handleTap(_ sender: UITapGestureRecognizer) {
            guard let controller, let editorScroll = editorScrollView else { return }
            let p = sender.location(in: contentView)
            let editorY = controller.editorContentY(fromMinimapY: p.y)
            let visibleH = editorScroll.bounds.height
            let editorH = max(controller.layout.lineIndex.height, controller.contentSize.height, 1)
            let maxY = max(0, editorH - visibleH)
            let target = min(maxY, max(0, editorY - visibleH * 0.3))
            editorScroll.setContentOffset(CGPoint(x: editorScroll.contentOffset.x, y: target), animated: false)
            updateViewport()
        }

        @objc private func handlePan(_ sender: UIPanGestureRecognizer) {
            guard let controller, let editorScroll = editorScrollView else { return }
            let translation = sender.translation(in: self)
            sender.setTranslation(.zero, in: self)
            let editorH = max(controller.layout.lineIndex.height, controller.contentSize.height, 1)
            let docMiniH = max(controller.minimapContentHeight(), 1)
            let stripH = max(bounds.height, 1)
            let availableH = min(docMiniH, stripH)
            let visibleH = max(editorScroll.bounds.height, 1)
            let maxEditorScroll = max(0, editorH - visibleH)
            guard maxEditorScroll > 0, availableH > 0 else { return }
            let travel = max(MinimapMetrics.lineHeight, availableH - MinimapMetrics.lineHeight)
            let deltaFraction = translation.y / travel
            var y = editorScroll.contentOffset.y + deltaFraction * maxEditorScroll
            y = min(maxEditorScroll, max(0, y))
            editorScroll.setContentOffset(CGPoint(x: editorScroll.contentOffset.x, y: y), animated: false)
            updateViewport()
        }
    }

    final class UIKitMinimapContentView: UIView {
        weak var controller: EditorController?

        override func draw(_ rect: CGRect) {
            guard let controller, let context = UIGraphicsGetCurrentContext() else { return }
            let snapshot = controller.minimapSnapshot(visibleMinimapRect: rect.insetBy(dx: 0, dy: -20))
            let theme = controller.configuration.theme

            for r in snapshot.selectionRects {
                context.setFillColor(theme.selection.withAlphaComponent(0.25).cgColor)
                context.fill(r)
            }
            for line in snapshot.lines {
                let bubbleH = max(1, line.height - 1)
                for bubble in line.bubbles {
                    let color = theme.color(for: bubble.capture)
                    context.setFillColor(color.cgColor)
                    context.fill(
                        CGRect(x: bubble.minimapX, y: line.y + 0.5, width: bubble.minimapWidth, height: bubbleH))
                }
            }
        }
    }
#endif
