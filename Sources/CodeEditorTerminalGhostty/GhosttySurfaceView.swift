import CodeEditorTerminal
import Foundation
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit

    /// AppKit host for a Ghostty-backed terminal surface (TER-004 / §21.6).
    ///
    /// Displays Ghostty snapshot text with monospaced rendering. When full Metal
    /// libghostty surface is linked, this view is the integration point for the
    /// layer; until then it uses ordered Ghostty controller snapshots — never
    /// custom `TerminalScreen` / `VTParser`.
    @MainActor
    public final class GhosttySurfaceView: NSView {
        public private(set) var sessionID: TerminalSessionID
        public var onKeyData: ((Data) -> Void)?
        private var textView: NSTextView!
        private var scrollView: NSScrollView!

        public init(sessionID: TerminalSessionID = TerminalSessionID()) {
            self.sessionID = sessionID
            super.init(frame: .zero)
            wantsLayer = true
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            let scroll = NSScrollView(frame: bounds)
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.contentView.bounds)
            tv.isEditable = true
            tv.isSelectable = true
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.autoresizingMask = [.width]
            tv.delegate = self
            scroll.documentView = tv
            addSubview(scroll)
            self.scrollView = scroll
            self.textView = tv
            setAccessibilityIdentifier("ghostty.surface")
            setAccessibilityElement(true)
            setAccessibilityRole(.textArea)
        }

        public override var acceptsFirstResponder: Bool { true }

        public override func layout() {
            super.layout()
            scrollView.frame = bounds
        }

        public func applySnapshot(_ text: String) {
            let selected = textView.selectedRange()
            textView.string = text
            if selected.location <= (text as NSString).length {
                textView.setSelectedRange(selected)
            }
            setAccessibilityValue(text)
        }

        public func bindSession(_ id: TerminalSessionID) {
            sessionID = id
        }
    }

    extension GhosttySurfaceView: NSTextViewDelegate {
        public func textDidChange(_ notification: Notification) {
            // Prefer keyDown path; TextView edit used for paste/IME commit.
        }

        public override func keyDown(with event: NSEvent) {
            if let chars = event.characters {
                onKeyData?(Data(chars.utf8))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// SwiftUI wrapper — stable identity by session ID (§21.6).
    public struct GhosttySurfaceRepresentable: NSViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var onKeyData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String,
            onKeyData: @escaping (Data) -> Void
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.onKeyData = onKeyData
        }

        public func makeNSView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID)
            v.onKeyData = onKeyData
            v.applySnapshot(snapshot)
            return v
        }

        public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
            nsView.bindSession(sessionID)
            nsView.onKeyData = onKeyData
            nsView.applySnapshot(snapshot)
        }
    }

#elseif canImport(UIKit)
    import UIKit

    /// iOS: remote-only surface host (no local PTY by default) — §21.12.
    @MainActor
    public final class GhosttySurfaceView: UIView {
        public private(set) var sessionID: TerminalSessionID
        public var onKeyData: ((Data) -> Void)?
        private let textView = UITextView()

        public init(sessionID: TerminalSessionID = TerminalSessionID()) {
            self.sessionID = sessionID
            super.init(frame: .zero)
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.isEditable = false
            textView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: topAnchor),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor),
                textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            accessibilityIdentifier = "ghostty.surface"
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public func applySnapshot(_ text: String) {
            textView.text = text
            accessibilityValue = text
        }

        public func bindSession(_ id: TerminalSessionID) { sessionID = id }
    }

    public struct GhosttySurfaceRepresentable: UIViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var onKeyData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String,
            onKeyData: @escaping (Data) -> Void
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.onKeyData = onKeyData
        }

        public func makeUIView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID)
            v.onKeyData = onKeyData
            v.applySnapshot(snapshot)
            return v
        }

        public func updateUIView(_ uiView: GhosttySurfaceView, context: Context) {
            uiView.bindSession(sessionID)
            uiView.onKeyData = onKeyData
            uiView.applySnapshot(snapshot)
        }
    }
#endif
