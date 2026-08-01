#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    import SwiftUI

    // MARK: - Floating popup container

    /// Hosts ``AnnotationPopupView`` as a floating subview of the editor.
    ///
    /// - Always claims mouse hits inside its bounds (NSHostingView alone can return `nil`
    ///   for transparent regions, which lets the editor steal the click and dismiss).
    /// - Supports fade + slight slide animation for show / dismiss.
    @MainActor
    final class AnnotationPopupContainer: NSView {
        private let hosting: NSHostingView<AnnotationPopupView>
        private(set) var lineIndex: Int

        init(annotations: [LineAnnotation], lineIndex: Int) {
            self.lineIndex = lineIndex
            self.hosting = NSHostingView(rootView: AnnotationPopupView(annotations: annotations))
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(hosting)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Prefer this view (or a descendant) for any point in our bounds so the editor
        /// does not receive the click and dismiss the popup.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // `point` is in the superview’s coordinate system.
            guard let superview else { return super.hitTest(point) }
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            return super.hitTest(point) ?? self
        }

        override var acceptsFirstResponder: Bool { true }

        override var isFlipped: Bool { true }

        /// Intrinsic content size of the SwiftUI tree (capped).
        func measureFittingSize() -> CGSize {
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            let width = min(320, max(180, fitting.width.isFinite ? fitting.width : 288))
            var height = fitting.height.isFinite ? fitting.height : 48
            if height < 24 || height > 480 {
                height = min(480, max(36, CGFloat(hosting.rootView.annotations.count) * 44))
            }
            return CGSize(width: width, height: height)
        }

        override func layout() {
            super.layout()
            hosting.frame = bounds
        }

        /// Fade / slide in at `frame`.
        func animateIn(to frame: CGRect) {
            self.frame = frame.offsetBy(dx: 0, dy: -4)
            alphaValue = 0
            hosting.frame = bounds
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
                animator().frame = frame
            }
        }

        /// Fade out, then remove from superview.
        func animateOut(completion: (@MainActor () -> Void)? = nil) {
            NSAnimationContext.runAnimationGroup(
                { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    animator().alphaValue = 0
                    animator().frame = frame.offsetBy(dx: 0, dy: -3)
                },
                completionHandler: { [weak self] in
                    DispatchQueue.main.async {
                        self?.removeFromSuperview()
                        completion?()
                    }
                })
        }
    }

    // MARK: - View-controller host (optional presentations)

    /// Lightweight host when a view controller is required.
    @MainActor
    final class AnnotationPopupHostController: NSViewController {
        private let annotations: [LineAnnotation]

        init(annotations: [LineAnnotation]) {
            self.annotations = annotations
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let root = AnnotationPopupView(annotations: annotations)
            let host = NSHostingView(rootView: root)
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let fitted = CGSize(
                width: min(360, max(220, size.width + 12)),
                height: max(44, size.height + 8)
            )
            host.frame = NSRect(origin: .zero, size: fitted)
            preferredContentSize = fitted
            view = host
        }
    }
#endif
