import CodeEditorTerminal
import Foundation
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit

    /// AppKit host for Ghostty-backed terminal display (TER-N02 / TER-N04 / §21.6).
    ///
    /// Integration claim: ``GhosttySessionController/integrationClaim``.
    /// When Ghostty is unlinked this view must not present a fake terminal as Ghostty.
    /// VT-engine path uses monospaced host rendering of Ghostty formatter plain text —
    /// not custom `TerminalScreen` / `VTParser`.
    @MainActor
    public final class GhosttySurfaceView: NSView {
        public private(set) var sessionID: TerminalSessionID
        public private(set) var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: ((GhosttyKeyEvent) -> Void)?
        /// Legacy raw-data path; prefer `onKeyEvent`.
        public var onKeyData: ((Data) -> Void)?
        private var textView: NSTextView!
        private var scrollView: NSScrollView!
        private var unavailableLabel: NSTextField?
        private var lastAppliedGeneration: UInt64 = 0

        public init(
            sessionID: TerminalSessionID = TerminalSessionID(),
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel
        ) {
            self.sessionID = sessionID
            self.integrationLevel = integrationLevel
            super.init(frame: .zero)
            wantsLayer = true
            setup()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setup() {
            if integrationLevel == .unavailable {
                let label = NSTextField(labelWithString: "Terminal unavailable: Ghostty not linked")
                label.alignment = .center
                label.textColor = .secondaryLabelColor
                label.autoresizingMask = [.width, .height]
                label.frame = bounds
                addSubview(label)
                unavailableLabel = label
                setAccessibilityIdentifier("ghostty.surface.unavailable")
                setAccessibilityElement(true)
                setAccessibilityRole(.staticText)
                setAccessibilityLabel(GhosttySessionController.integrationClaim)
                return
            }

            let scroll = NSScrollView(frame: bounds)
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            let tv = NSTextView(frame: scroll.contentView.bounds)
            tv.isEditable = false
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
            setAccessibilityLabel(GhosttySessionController.integrationClaim)
        }

        public override var acceptsFirstResponder: Bool { integrationLevel != .unavailable }

        public override func layout() {
            super.layout()
            scrollView?.frame = bounds
            unavailableLabel?.frame = bounds
        }

        /// Apply viewport text only when generation advances (TER-N06 dirty tracking).
        public func applySnapshot(_ text: String, generation: UInt64 = 0) {
            guard integrationLevel != .unavailable, let textView else { return }
            if generation > 0 && generation < lastAppliedGeneration { return }
            if generation > 0 { lastAppliedGeneration = generation }
            let selected = textView.selectedRange()
            textView.string = text
            if selected.location <= (text as NSString).length {
                textView.setSelectedRange(selected)
            }
            setAccessibilityValue(text)
        }

        public func applySnapshot(_ text: String) {
            applySnapshot(text, generation: lastAppliedGeneration &+ 1)
        }

        public func bindSession(_ id: TerminalSessionID) {
            sessionID = id
        }

        public override func keyDown(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.keyDown(with: event)
                return
            }
            var mods: UInt16 = 0
            if event.modifierFlags.contains(.shift) { mods |= GhosttyKeyEvent.modShift }
            if event.modifierFlags.contains(.control) { mods |= GhosttyKeyEvent.modCtrl }
            if event.modifierFlags.contains(.option) { mods |= GhosttyKeyEvent.modAlt }
            if event.modifierFlags.contains(.command) { mods |= GhosttyKeyEvent.modSuper }

            let chars = event.charactersIgnoringModifiers ?? event.characters
            let keyEvent = GhosttyKeyEvent(
                key: 0,
                mods: mods,
                action: .press,
                composing: false,
                text: event.characters
            )
            if let onKeyEvent {
                onKeyEvent(keyEvent)
            } else if let chars = event.characters {
                onKeyData?(Data(chars.utf8))
            } else {
                super.keyDown(with: event)
            }
            _ = chars
        }

        public override func flagsChanged(with event: NSEvent) {
            // Route modifier-only changes when needed by Kitty keyboard protocol.
            super.flagsChanged(with: event)
        }
    }

    extension GhosttySurfaceView: NSTextViewDelegate {}

    /// SwiftUI wrapper — stable identity by session ID (§21.6).
    public struct GhosttySurfaceRepresentable: NSViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var generation: UInt64
        public var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: (GhosttyKeyEvent) -> Void
        public var onKeyData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String,
            generation: UInt64 = 0,
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel,
            onKeyEvent: @escaping (GhosttyKeyEvent) -> Void = { _ in },
            onKeyData: @escaping (Data) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.generation = generation
            self.integrationLevel = integrationLevel
            self.onKeyEvent = onKeyEvent
            self.onKeyData = onKeyData
        }

        public func makeNSView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID, integrationLevel: integrationLevel)
            v.onKeyEvent = onKeyEvent
            v.onKeyData = onKeyData
            v.applySnapshot(snapshot, generation: generation)
            return v
        }

        public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
            nsView.bindSession(sessionID)
            nsView.onKeyEvent = onKeyEvent
            nsView.onKeyData = onKeyData
            nsView.applySnapshot(snapshot, generation: generation)
        }
    }

#elseif canImport(UIKit)
    import UIKit

    /// iOS: remote-only surface host (no local PTY by default) — §21.12 / TER-N08.
    @MainActor
    public final class GhosttySurfaceView: UIView {
        public private(set) var sessionID: TerminalSessionID
        public private(set) var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: ((GhosttyKeyEvent) -> Void)?
        public var onKeyData: ((Data) -> Void)?
        private let textView = UITextView()
        private let unavailableLabel = UILabel()
        private var lastAppliedGeneration: UInt64 = 0

        public init(
            sessionID: TerminalSessionID = TerminalSessionID(),
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel
        ) {
            self.sessionID = sessionID
            self.integrationLevel = integrationLevel
            super.init(frame: .zero)
            if integrationLevel == .unavailable {
                unavailableLabel.text = "Terminal unavailable: Ghostty not linked"
                unavailableLabel.textAlignment = .center
                unavailableLabel.translatesAutoresizingMaskIntoConstraints = false
                addSubview(unavailableLabel)
                NSLayoutConstraint.activate([
                    unavailableLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                    unavailableLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
                accessibilityIdentifier = "ghostty.surface.unavailable"
            } else {
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
            accessibilityLabel = GhosttySessionController.integrationClaim
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public func applySnapshot(_ text: String, generation: UInt64 = 0) {
            guard integrationLevel != .unavailable else { return }
            if generation > 0 && generation < lastAppliedGeneration { return }
            if generation > 0 { lastAppliedGeneration = generation }
            textView.text = text
            accessibilityValue = text
        }

        public func applySnapshot(_ text: String) {
            applySnapshot(text, generation: lastAppliedGeneration &+ 1)
        }

        public func bindSession(_ id: TerminalSessionID) { sessionID = id }
    }

    public struct GhosttySurfaceRepresentable: UIViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var generation: UInt64
        public var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: (GhosttyKeyEvent) -> Void
        public var onKeyData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String,
            generation: UInt64 = 0,
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel,
            onKeyEvent: @escaping (GhosttyKeyEvent) -> Void = { _ in },
            onKeyData: @escaping (Data) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.generation = generation
            self.integrationLevel = integrationLevel
            self.onKeyEvent = onKeyEvent
            self.onKeyData = onKeyData
        }

        public func makeUIView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID, integrationLevel: integrationLevel)
            v.onKeyEvent = onKeyEvent
            v.onKeyData = onKeyData
            v.applySnapshot(snapshot, generation: generation)
            return v
        }

        public func updateUIView(_ uiView: GhosttySurfaceView, context: Context) {
            uiView.bindSession(sessionID)
            uiView.onKeyEvent = onKeyEvent
            uiView.onKeyData = onKeyData
            uiView.applySnapshot(snapshot, generation: generation)
        }
    }
#endif
