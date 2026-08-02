import CodeEditorTerminal
import Foundation
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit

    /// AppKit host for Ghostty-backed terminal display (TER-N02 / TER-N04 / TER-N06 / §21.6).
    ///
    /// Integration claim: ``GhosttySessionController/integrationClaim``.
    /// When Ghostty is unlinked this view must not present a fake terminal as Ghostty.
    ///
    /// **Honest VT-engine path (TER-N02 temporary level):** monospaced host CoreText-backed
    /// line buffer fed from Ghostty VT state via dirty-line deltas — not a full Ghostty
    /// Metal surface and never custom `TerminalScreen` / `VTParser`. Claim string is
    /// "Ghostty VT engine + CodeEditor renderer", never "Ghostty UI".
    ///
    /// Input routing (TER-N04): native events → structured Ghostty events → host callbacks
    /// (never raw `event.characters` alone for arrows/nav/Fn). Mouse/focus/paste bytes are
    /// produced by Ghostty encoders on the controller, not hand-built CSI in this view.
    @MainActor
    public final class GhosttySurfaceView: NSView {
        public private(set) var sessionID: TerminalSessionID
        public private(set) var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: ((GhosttyKeyEvent) -> Void)?
        public var onMouseEvent: ((GhosttyMouseEvent) -> Void)?
        public var onFocusEvent: ((GhosttyFocusEvent) -> Void)?
        public var onPasteData: ((Data) -> Void)?
        public var onIMEEvent: ((GhosttyIMEEvent) -> Void)?
        /// Legacy raw-data path; prefer `onKeyEvent`.
        public var onKeyData: ((Data) -> Void)?
        /// Whether the terminal has enabled focus-in/out reporting (DECSET 1004).
        public var focusReportingEnabled: Bool = false
        /// Mouse reporting mode (DECSET 1000/1002/1003/1006).
        public var mouseReportingMode: GhosttyMouseEvent.ReportingMode = .off
        /// Whether bracketed paste is active (DECSET 2004).
        public var bracketedPasteEnabled: Bool = false
        /// Approximate cell size for mouse cell coordinates.
        public var cellSize: CGSize = CGSize(width: 8, height: 16)

        private var textView: NSTextView!
        private var scrollView: NSScrollView!
        private var unavailableLabel: NSTextField?
        private var lastAppliedGeneration: UInt64 = 0
        /// Line-oriented viewport cache (TER-N06) — dirty indices only mutate changed rows.
        private var lineCache: [String] = []
        private var lastModifierFlags: NSEvent.ModifierFlags = []
        private var imeComposing = false

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

        /// Apply a dirty-line viewport delta from Ghostty (TER-N02/N06).
        ///
        /// Only mutates changed lines in the text storage when `fullRefresh` is false.
        /// Never appends growing scrollback strings on every poll.
        public func applyViewportDelta(_ delta: GhosttyViewportDelta) {
            guard integrationLevel != .unavailable, let textView else { return }
            if delta.generation > 0 && delta.generation < lastAppliedGeneration { return }
            if delta.generation > 0 { lastAppliedGeneration = delta.generation }

            if delta.fullRefresh || lineCache.count != delta.lines.count {
                lineCache = delta.lines
                let joined = delta.joinedPlainText
                textView.string = joined
                setAccessibilityValue(joined)
                return
            }

            // Line-level replace for dirty rows only (TER-N06).
            guard let storage = textView.textStorage else {
                lineCache = delta.lines
                textView.string = delta.joinedPlainText
                setAccessibilityValue(textView.string)
                return
            }
            storage.beginEditing()
            for row in delta.dirtyLineIndices where row >= 0 && row < delta.lines.count {
                let newLine = delta.lines[row]
                if row < lineCache.count, lineCache[row] == newLine { continue }
                // Rebuild from line cache mutation then single storage replace for dirty span.
                if row < lineCache.count {
                    lineCache[row] = newLine
                }
            }
            // Ensure cache length matches.
            if lineCache.count != delta.lines.count {
                lineCache = delta.lines
            } else {
                for row in delta.dirtyLineIndices where row >= 0 && row < delta.lines.count {
                    lineCache[row] = delta.lines[row]
                }
            }
            let joined = lineCache.joined(separator: "\n")
            let full = NSRange(location: 0, length: storage.length)
            storage.replaceCharacters(in: full, with: joined)
            storage.endEditing()
            setAccessibilityValue(joined)
        }

        /// Legacy full-string apply — converts to a full-refresh dirty delta (TER-N06).
        public func applySnapshot(_ text: String, generation: UInt64 = 0) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let delta = GhosttyViewportDelta(
                generation: generation == 0 ? (lastAppliedGeneration &+ 1) : generation,
                cols: 0,
                rows: lines.count,
                lines: lines,
                dirtyLineIndices: Array(0..<lines.count),
                fullRefresh: true
            )
            applyViewportDelta(delta)
        }

        public func applySnapshot(_ text: String) {
            applySnapshot(text, generation: lastAppliedGeneration &+ 1)
        }

        /// Whether the surface uses dirty-line rendering (TER-N06 production path).
        public var usesDirtyLineRendering: Bool { true }

        /// Current cached line count (tests / diagnostics).
        public var cachedLineCount: Int { lineCache.count }

        public func bindSession(_ id: TerminalSessionID) {
            sessionID = id
        }

        // MARK: - Keyboard (TER-N04)

        public override func keyDown(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.keyDown(with: event)
                return
            }
            if imeComposing {
                // Let the input context drive IME until commit.
                interpretKeyEvents([event])
                return
            }
            let keyEvent = GhosttyNativeInput.keyEvent(from: event, action: .press)
            // Require non-zero physical key for arrows/nav/Fn (never key:0 alone).
            emitKey(keyEvent)
        }

        public override func keyUp(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.keyUp(with: event)
                return
            }
            let keyEvent = GhosttyNativeInput.keyEvent(from: event, action: .release)
            emitKey(keyEvent)
        }

        public override func flagsChanged(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.flagsChanged(with: event)
                return
            }
            if let keyEvent = GhosttyNativeInput.flagsChanged(from: event, previous: lastModifierFlags) {
                emitKey(keyEvent)
            }
            lastModifierFlags = event.modifierFlags
        }

        // MARK: - Mouse (TER-N04)

        public override func mouseDown(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.mouseDown(with: event)
                return
            }
            emitMouse(GhosttyNativeInput.mouseEvent(
                from: event, action: .press, cellSize: cellSize, reportingMode: mouseReportingMode
            ))
        }

        public override func mouseUp(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.mouseUp(with: event)
                return
            }
            emitMouse(GhosttyNativeInput.mouseEvent(
                from: event, action: .release, cellSize: cellSize, reportingMode: mouseReportingMode
            ))
        }

        public override func mouseDragged(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.mouseDragged(with: event)
                return
            }
            emitMouse(GhosttyNativeInput.mouseEvent(
                from: event, action: .drag, cellSize: cellSize, reportingMode: mouseReportingMode
            ))
        }

        public override func rightMouseDown(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.rightMouseDown(with: event)
                return
            }
            emitMouse(GhosttyNativeInput.mouseEvent(
                from: event, action: .press, cellSize: cellSize, reportingMode: mouseReportingMode
            ))
        }

        public override func scrollWheel(with event: NSEvent) {
            guard integrationLevel != .unavailable else {
                super.scrollWheel(with: event)
                return
            }
            emitMouse(GhosttyNativeInput.mouseEvent(
                from: event, action: .press, cellSize: cellSize, reportingMode: mouseReportingMode
            ))
        }

        // MARK: - Focus (TER-N04)

        public override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok, integrationLevel != .unavailable {
                onFocusEvent?(GhosttyFocusEvent(focused: true, reportingEnabled: focusReportingEnabled))
            }
            return ok
        }

        public override func resignFirstResponder() -> Bool {
            if integrationLevel != .unavailable {
                onFocusEvent?(GhosttyFocusEvent(focused: false, reportingEnabled: focusReportingEnabled))
            }
            return super.resignFirstResponder()
        }

        // MARK: - Paste / IME (TER-N04)

        /// Paste clipboard text with optional bracketed-paste framing (TER-N04).
        @objc public func paste(_ sender: Any?) {
            guard integrationLevel != .unavailable else { return }
            let pb = NSPasteboard.general.string(forType: .string) ?? ""
            performPaste(pb)
        }

        /// Paste an explicit string (tests / host pasteboard adapters).
        public func performPaste(_ text: String) {
            guard integrationLevel != .unavailable else { return }
            let data = GhosttyNativeInput.encodePaste(text, bracketed: bracketedPasteEnabled)
            if let onPasteData {
                onPasteData(data)
            } else {
                onKeyData?(data)
            }
        }

        public override func insertText(_ insertString: Any) {
            guard integrationLevel != .unavailable else { return }
            let text: String
            if let s = insertString as? String {
                text = s
            } else if let s = insertString as? NSAttributedString {
                text = s.string
            } else {
                return
            }
            if imeComposing {
                onIMEEvent?(.commit(text))
                imeComposing = false
            }
            if !text.isEmpty {
                emitKey(GhosttyKeyEvent(key: 0, mods: 0, action: .press, composing: false, text: text))
            }
        }

        /// IME preedit update (TER-N04). Call from input context / host.
        public func applyIMEMarkedText(_ string: Any) {
            guard integrationLevel != .unavailable else { return }
            let text: String
            if let s = string as? String {
                text = s
            } else if let s = string as? NSAttributedString {
                text = s.string
            } else {
                text = ""
            }
            if !imeComposing {
                onIMEEvent?(.beginComposition)
                imeComposing = true
            }
            onIMEEvent?(.updateComposition(text))
        }

        /// Cancel IME composition without committing (TER-N04).
        public func cancelIME() {
            if imeComposing {
                onIMEEvent?(.cancel)
                imeComposing = false
            }
        }

        public var isIMEComposing: Bool { imeComposing }

        // MARK: - Helpers

        private func emitKey(_ keyEvent: GhosttyKeyEvent) {
            if let onKeyEvent {
                onKeyEvent(keyEvent)
            } else if let text = keyEvent.text, !text.isEmpty {
                onKeyData?(Data(text.utf8))
            }
        }

        private func emitMouse(_ event: GhosttyMouseEvent) {
            // TER-N04: surface emits structured mouse events only.
            // Encoded CSI/SGR bytes must come from GhosttySessionController.encodeMouse
            // (Ghostty mouse encoder), never a hand-built map in the view.
            onMouseEvent?(event)
        }
    }

    extension GhosttySurfaceView: NSTextViewDelegate {}

    /// SwiftUI wrapper — stable identity by session ID (§21.6).
    public struct GhosttySurfaceRepresentable: NSViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var generation: UInt64
        public var viewportDelta: GhosttyViewportDelta?
        public var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: (GhosttyKeyEvent) -> Void
        public var onKeyData: (Data) -> Void
        public var onMouseEvent: (GhosttyMouseEvent) -> Void
        public var onFocusEvent: (GhosttyFocusEvent) -> Void
        public var onPasteData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String = "",
            generation: UInt64 = 0,
            viewportDelta: GhosttyViewportDelta? = nil,
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel,
            onKeyEvent: @escaping (GhosttyKeyEvent) -> Void = { _ in },
            onKeyData: @escaping (Data) -> Void = { _ in },
            onMouseEvent: @escaping (GhosttyMouseEvent) -> Void = { _ in },
            onFocusEvent: @escaping (GhosttyFocusEvent) -> Void = { _ in },
            onPasteData: @escaping (Data) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.generation = generation
            self.viewportDelta = viewportDelta
            self.integrationLevel = integrationLevel
            self.onKeyEvent = onKeyEvent
            self.onKeyData = onKeyData
            self.onMouseEvent = onMouseEvent
            self.onFocusEvent = onFocusEvent
            self.onPasteData = onPasteData
        }

        public func makeNSView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID, integrationLevel: integrationLevel)
            v.onKeyEvent = onKeyEvent
            v.onKeyData = onKeyData
            v.onMouseEvent = onMouseEvent
            v.onFocusEvent = onFocusEvent
            v.onPasteData = onPasteData
            if let viewportDelta {
                v.applyViewportDelta(viewportDelta)
            } else if !snapshot.isEmpty {
                v.applySnapshot(snapshot, generation: generation)
            }
            return v
        }

        public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
            nsView.bindSession(sessionID)
            nsView.onKeyEvent = onKeyEvent
            nsView.onKeyData = onKeyData
            nsView.onMouseEvent = onMouseEvent
            nsView.onFocusEvent = onFocusEvent
            nsView.onPasteData = onPasteData
            if let viewportDelta {
                nsView.applyViewportDelta(viewportDelta)
            } else if !snapshot.isEmpty {
                nsView.applySnapshot(snapshot, generation: generation)
            }
        }
    }

#elseif canImport(UIKit)
    import UIKit

    /// iOS: remote-only surface host (no local PTY by default) — §21.12 / TER-N08.
    /// Input routes through structured Ghostty events (TER-N04).
    @MainActor
    public final class GhosttySurfaceView: UIView, UIKeyInput, UITextInputTraits {
        public private(set) var sessionID: TerminalSessionID
        public private(set) var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: ((GhosttyKeyEvent) -> Void)?
        public var onMouseEvent: ((GhosttyMouseEvent) -> Void)?
        public var onFocusEvent: ((GhosttyFocusEvent) -> Void)?
        public var onPasteData: ((Data) -> Void)?
        public var onIMEEvent: ((GhosttyIMEEvent) -> Void)?
        public var onKeyData: ((Data) -> Void)?
        public var focusReportingEnabled: Bool = false
        public var mouseReportingMode: GhosttyMouseEvent.ReportingMode = .off
        public var bracketedPasteEnabled: Bool = false
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
            isAccessibilityElement = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override var canBecomeFirstResponder: Bool { integrationLevel != .unavailable }

        @discardableResult
        public override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocusEvent?(GhosttyFocusEvent(focused: true, reportingEnabled: focusReportingEnabled)) }
            return ok
        }

        @discardableResult
        public override func resignFirstResponder() -> Bool {
            onFocusEvent?(GhosttyFocusEvent(focused: false, reportingEnabled: focusReportingEnabled))
            return super.resignFirstResponder()
        }

        public var hasText: Bool { !(textView.text ?? "").isEmpty }

        public func insertText(_ text: String) {
            guard integrationLevel != .unavailable else { return }
            onKeyEvent?(GhosttyKeyEvent(key: 0, mods: 0, action: .press, composing: false, text: text))
        }

        public func deleteBackward() {
            guard integrationLevel != .unavailable else { return }
            onKeyEvent?(GhosttyKeyEvent(
                key: GhosttyPhysicalKey.backspace.rawValue,
                mods: 0,
                action: .press
            ))
        }

        public func applyViewportDelta(_ delta: GhosttyViewportDelta) {
            guard integrationLevel != .unavailable else { return }
            if delta.generation > 0 && delta.generation < lastAppliedGeneration { return }
            if delta.generation > 0 { lastAppliedGeneration = delta.generation }
            let joined = delta.joinedPlainText
            textView.text = joined
            accessibilityValue = joined
        }

        public func applySnapshot(_ text: String, generation: UInt64 = 0) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            applyViewportDelta(
                GhosttyViewportDelta(
                    generation: generation == 0 ? (lastAppliedGeneration &+ 1) : generation,
                    cols: 0,
                    rows: lines.count,
                    lines: lines,
                    dirtyLineIndices: Array(0..<lines.count),
                    fullRefresh: true
                )
            )
        }

        public func applySnapshot(_ text: String) {
            applySnapshot(text, generation: lastAppliedGeneration &+ 1)
        }

        public var usesDirtyLineRendering: Bool { true }
        public var cachedLineCount: Int { 0 }

        public func bindSession(_ id: TerminalSessionID) { sessionID = id }

        /// Route a pressesBegan press (arrows / nav) into structured Ghostty keys.
        public func handlePresses(_ presses: Set<UIPress>) {
            guard integrationLevel != .unavailable else { return }
            for press in presses {
                guard let key = press.key else { continue }
                let code = key.keyCode
                // Map a subset of UIKeyboardHIDUsage to Ghostty keys.
                let physical: GhosttyPhysicalKey
                switch code {
                case .keyboardUpArrow: physical = .arrowUp
                case .keyboardDownArrow: physical = .arrowDown
                case .keyboardLeftArrow: physical = .arrowLeft
                case .keyboardRightArrow: physical = .arrowRight
                case .keyboardEscape: physical = .escape
                case .keyboardReturnOrEnter: physical = .enter
                case .keyboardTab: physical = .tab
                case .keyboardDeleteOrBackspace: physical = .backspace
                case .keyboardF1: physical = .f1
                case .keyboardF2: physical = .f2
                case .keyboardF3: physical = .f3
                case .keyboardF4: physical = .f4
                case .keyboardF5: physical = .f5
                case .keyboardF6: physical = .f6
                case .keyboardF7: physical = .f7
                case .keyboardF8: physical = .f8
                case .keyboardF9: physical = .f9
                case .keyboardF10: physical = .f10
                case .keyboardF11: physical = .f11
                case .keyboardF12: physical = .f12
                default: physical = .unidentified
                }
                var mods: UInt16 = 0
                if key.modifierFlags.contains(.shift) { mods |= GhosttyKeyEvent.modShift }
                if key.modifierFlags.contains(.control) { mods |= GhosttyKeyEvent.modCtrl }
                if key.modifierFlags.contains(.alternate) { mods |= GhosttyKeyEvent.modAlt }
                if key.modifierFlags.contains(.command) { mods |= GhosttyKeyEvent.modSuper }
                onKeyEvent?(GhosttyKeyEvent(
                    key: physical.rawValue,
                    mods: mods,
                    action: .press,
                    text: key.characters
                ))
            }
        }
    }

    public struct GhosttySurfaceRepresentable: UIViewRepresentable {
        public var sessionID: TerminalSessionID
        public var snapshot: String
        public var generation: UInt64
        public var viewportDelta: GhosttyViewportDelta?
        public var integrationLevel: GhosttyIntegrationLevel
        public var onKeyEvent: (GhosttyKeyEvent) -> Void
        public var onKeyData: (Data) -> Void
        public var onMouseEvent: (GhosttyMouseEvent) -> Void
        public var onFocusEvent: (GhosttyFocusEvent) -> Void
        public var onPasteData: (Data) -> Void

        public init(
            sessionID: TerminalSessionID,
            snapshot: String = "",
            generation: UInt64 = 0,
            viewportDelta: GhosttyViewportDelta? = nil,
            integrationLevel: GhosttyIntegrationLevel = GhosttySessionController.currentIntegrationLevel,
            onKeyEvent: @escaping (GhosttyKeyEvent) -> Void = { _ in },
            onKeyData: @escaping (Data) -> Void = { _ in },
            onMouseEvent: @escaping (GhosttyMouseEvent) -> Void = { _ in },
            onFocusEvent: @escaping (GhosttyFocusEvent) -> Void = { _ in },
            onPasteData: @escaping (Data) -> Void = { _ in }
        ) {
            self.sessionID = sessionID
            self.snapshot = snapshot
            self.generation = generation
            self.viewportDelta = viewportDelta
            self.integrationLevel = integrationLevel
            self.onKeyEvent = onKeyEvent
            self.onKeyData = onKeyData
            self.onMouseEvent = onMouseEvent
            self.onFocusEvent = onFocusEvent
            self.onPasteData = onPasteData
        }

        public func makeUIView(context: Context) -> GhosttySurfaceView {
            let v = GhosttySurfaceView(sessionID: sessionID, integrationLevel: integrationLevel)
            v.onKeyEvent = onKeyEvent
            v.onKeyData = onKeyData
            v.onMouseEvent = onMouseEvent
            v.onFocusEvent = onFocusEvent
            v.onPasteData = onPasteData
            if let viewportDelta {
                v.applyViewportDelta(viewportDelta)
            } else if !snapshot.isEmpty {
                v.applySnapshot(snapshot, generation: generation)
            }
            return v
        }

        public func updateUIView(_ uiView: GhosttySurfaceView, context: Context) {
            uiView.bindSession(sessionID)
            uiView.onKeyEvent = onKeyEvent
            uiView.onKeyData = onKeyData
            uiView.onMouseEvent = onMouseEvent
            uiView.onFocusEvent = onFocusEvent
            uiView.onPasteData = onPasteData
            if let viewportDelta {
                uiView.applyViewportDelta(viewportDelta)
            } else if !snapshot.isEmpty {
                uiView.applySnapshot(snapshot, generation: generation)
            }
        }
    }
#endif
