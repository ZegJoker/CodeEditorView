import CodeEditorTerminal
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif
#if canImport(UIKit)
    import UIKit
#endif

// MARK: - Structured mouse / focus / IME (TER-N04)

/// Mouse reporting event routed to Ghostty input state (TER-N04).
public struct GhosttyMouseEvent: Sendable, Hashable {
    public enum Button: UInt8, Sendable, Hashable {
        case none = 0
        case left = 1
        case middle = 2
        case right = 3
        case wheelUp = 4
        case wheelDown = 5
        case wheelLeft = 6
        case wheelRight = 7
    }

    public enum Action: UInt8, Sendable, Hashable {
        case press = 1
        case release = 2
        case move = 3
        case drag = 4
    }

    /// Reporting mode when the terminal has enabled mouse tracking.
    public enum ReportingMode: UInt8, Sendable, Hashable {
        case off = 0
        case x10 = 1
        case utf8 = 2
        case sgr = 3
        case urxvt = 4
    }

    public var button: Button
    public var action: Action
    public var mods: UInt16
    /// 1-based cell column.
    public var col: Int
    /// 1-based cell row.
    public var row: Int
    public var reportingMode: ReportingMode

    public init(
        button: Button = .left,
        action: Action = .press,
        mods: UInt16 = 0,
        col: Int = 1,
        row: Int = 1,
        reportingMode: ReportingMode = .sgr
    ) {
        self.button = button
        self.action = action
        self.mods = mods
        self.col = max(1, col)
        self.row = max(1, row)
        self.reportingMode = reportingMode
    }

    /// Encode SGR mouse report when reporting is enabled; empty when `.off`.
    public func encode() -> Data {
        guard reportingMode != .off else { return Data() }
        // SGR: CSI < Cb ; Cx ; Cy M/m
        var cb = Int(button.rawValue)
        if mods & GhosttyKeyEvent.modShift != 0 { cb += 4 }
        if mods & GhosttyKeyEvent.modAlt != 0 { cb += 8 }
        if mods & GhosttyKeyEvent.modCtrl != 0 { cb += 16 }
        if action == .move || action == .drag { cb += 32 }
        let final: Character = (action == .release) ? "m" : "M"
        let seq = "\u{1b}[<\(cb);\(col);\(row)\(final)"
        return Data(seq.utf8)
    }
}

/// Focus in/out reporting (DECSET 1004) — TER-N04.
public struct GhosttyFocusEvent: Sendable, Hashable {
    public var focused: Bool
    public var reportingEnabled: Bool

    public init(focused: Bool, reportingEnabled: Bool = true) {
        self.focused = focused
        self.reportingEnabled = reportingEnabled
    }

    /// ESC [ I (focus in) / ESC [ O (focus out) when reporting enabled.
    public func encode() -> Data {
        guard reportingEnabled else { return Data() }
        return Data((focused ? "\u{1b}[I" : "\u{1b}[O").utf8)
    }
}

/// IME / dead-key composition events (TER-N04).
public enum GhosttyIMEEvent: Sendable, Hashable {
    case beginComposition
    case updateComposition(String)
    case commit(String)
    case cancel

    /// Committed text becomes a key event with composing=false; preedit does not write PTY bytes.
    public var committedKeyEvent: GhosttyKeyEvent? {
        switch self {
        case .commit(let text) where !text.isEmpty:
            return GhosttyKeyEvent(key: 0, mods: 0, action: .press, composing: false, text: text)
        case .updateComposition(let text) where !text.isEmpty:
            return GhosttyKeyEvent(key: 0, mods: 0, action: .press, composing: true, text: text)
        case .beginComposition, .cancel, .commit, .updateComposition:
            return nil
        }
    }
}

// MARK: - Platform → Ghostty mapping

/// Maps native platform events to Ghostty structured input (TER-N04).
///
/// Does **not** invent PTY bytes; callers pass structured events to
/// ``GhosttySessionController/encodeKey(_:)`` (or paste/mouse/focus encoders).
public enum GhosttyNativeInput {
    /// macOS virtual key codes → Ghostty physical keys.
    public static func physicalKey(macOSKeyCode code: UInt16) -> GhosttyPhysicalKey {
        switch code {
        // Letters (ANSI)
        case 0: return .a
        case 1: return .s
        case 2: return .d
        case 3: return .f
        case 4: return .h
        case 5: return .g
        case 6: return .z
        case 7: return .x
        case 8: return .c
        case 9: return .v
        case 11: return .b
        case 12: return .q
        case 13: return .w
        case 14: return .e
        case 15: return .r
        case 16: return .y
        case 17: return .t
        case 31: return .o
        case 32: return .u
        case 34: return .i
        case 35: return .p
        case 37: return .l
        case 38: return .j
        case 40: return .k
        case 45: return .n
        case 46: return .m
        // Digits
        case 18: return .digit1
        case 19: return .digit2
        case 20: return .digit3
        case 21: return .digit4
        case 22: return .digit6
        case 23: return .digit5
        case 25: return .digit9
        case 26: return .digit7
        case 28: return .digit8
        case 29: return .digit0
        // Punctuation
        case 24: return .equal
        case 27: return .minus
        case 33: return .bracketLeft
        case 30: return .bracketRight
        case 41: return .semicolon
        case 39: return .quote
        case 42: return .backslash
        case 43: return .comma
        case 47: return .period
        case 44: return .slash
        case 50: return .backquote
        // Controls / nav
        case 36, 76: return .enter
        case 48: return .tab
        case 49: return .space
        case 51: return .backspace
        case 53: return .escape
        case 117: return .delete
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 114: return .insert
        case 123: return .arrowLeft
        case 124: return .arrowRight
        case 125: return .arrowDown
        case 126: return .arrowUp
        // Function keys
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        // Modifiers
        case 56: return .shiftLeft
        case 60: return .shiftRight
        case 59: return .controlLeft
        case 62: return .controlRight
        case 58: return .altLeft
        case 61: return .altRight
        case 55: return .metaLeft
        case 54: return .metaRight
        case 63: return .fn
        default: return .unidentified
        }
    }

    public static func mods(from flags: UInt) -> UInt16 {
        var mods: UInt16 = 0
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            let f = NSEvent.ModifierFlags(rawValue: flags)
            if f.contains(.shift) { mods |= GhosttyKeyEvent.modShift }
            if f.contains(.control) { mods |= GhosttyKeyEvent.modCtrl }
            if f.contains(.option) { mods |= GhosttyKeyEvent.modAlt }
            if f.contains(.command) { mods |= GhosttyKeyEvent.modSuper }
        #else
            // Bit layout matches NSEvent when AppKit unavailable (tests).
            if flags & (1 << 17) != 0 { mods |= GhosttyKeyEvent.modShift } // shiftKey
            if flags & (1 << 18) != 0 { mods |= GhosttyKeyEvent.modCtrl }
            if flags & (1 << 19) != 0 { mods |= GhosttyKeyEvent.modAlt }
            if flags & (1 << 20) != 0 { mods |= GhosttyKeyEvent.modSuper }
        #endif
        return mods
    }

    /// Build a structured key event from macOS key code + modifier raw value + text.
    public static func keyEvent(
        macOSKeyCode code: UInt16,
        modifierFlagsRaw: UInt,
        action: GhosttyKeyEvent.Action = .press,
        composing: Bool = false,
        text: String? = nil
    ) -> GhosttyKeyEvent {
        let physical = physicalKey(macOSKeyCode: code)
        return GhosttyKeyEvent(
            key: physical.rawValue,
            mods: mods(from: modifierFlagsRaw),
            action: action,
            composing: composing,
            text: text
        )
    }

    /// flagsChanged: emit press or release for the modifier that transitioned.
    public static func flagsChangedEvent(
        macOSKeyCode code: UInt16,
        modifierFlagsRaw: UInt,
        previousModifierFlagsRaw: UInt
    ) -> GhosttyKeyEvent? {
        let physical = physicalKey(macOSKeyCode: code)
        guard physical != .unidentified else { return nil }
        let now = mods(from: modifierFlagsRaw)
        let prev = mods(from: previousModifierFlagsRaw)
        let bit: UInt16
        switch physical {
        case .shiftLeft, .shiftRight: bit = GhosttyKeyEvent.modShift
        case .controlLeft, .controlRight: bit = GhosttyKeyEvent.modCtrl
        case .altLeft, .altRight: bit = GhosttyKeyEvent.modAlt
        case .metaLeft, .metaRight: bit = GhosttyKeyEvent.modSuper
        default: return nil
        }
        let wasOn = prev & bit != 0
        let isOn = now & bit != 0
        if wasOn == isOn {
            // Still emit a press with current mods so Kitty protocol can observe state.
            return GhosttyKeyEvent(key: physical.rawValue, mods: now, action: isOn ? .press : .release)
        }
        return GhosttyKeyEvent(
            key: physical.rawValue,
            mods: now,
            action: isOn ? .press : .release
        )
    }

    /// Bracketed paste payload (uses shared ``TerminalPaste``).
    public static func encodePaste(_ text: String, bracketed: Bool) -> Data {
        TerminalPaste.encode(text, bracketed: bracketed)
    }

    public static func encodeFocus(_ event: GhosttyFocusEvent) -> Data {
        event.encode()
    }

    public static func encodeMouse(_ event: GhosttyMouseEvent) -> Data {
        event.encode()
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        public static func keyEvent(from event: NSEvent, action: GhosttyKeyEvent.Action = .press) -> GhosttyKeyEvent {
            let text = event.characters
            let composing = false
            return keyEvent(
                macOSKeyCode: event.keyCode,
                modifierFlagsRaw: event.modifierFlags.rawValue,
                action: action,
                composing: composing,
                text: text
            )
        }

        public static func flagsChanged(from event: NSEvent, previous: NSEvent.ModifierFlags) -> GhosttyKeyEvent? {
            flagsChangedEvent(
                macOSKeyCode: event.keyCode,
                modifierFlagsRaw: event.modifierFlags.rawValue,
                previousModifierFlagsRaw: previous.rawValue
            )
        }

        public static func mouseEvent(
            from event: NSEvent,
            action: GhosttyMouseEvent.Action,
            cellSize: CGSize,
            reportingMode: GhosttyMouseEvent.ReportingMode
        ) -> GhosttyMouseEvent {
            let col = max(1, Int(event.locationInWindow.x / max(cellSize.width, 1)) + 1)
            let row = max(1, Int(event.locationInWindow.y / max(cellSize.height, 1)) + 1)
            let button: GhosttyMouseEvent.Button
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
                button = .left
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                button = .right
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                button = .middle
            case .scrollWheel:
                button = event.scrollingDeltaY > 0 ? .wheelUp : .wheelDown
            default:
                button = .left
            }
            return GhosttyMouseEvent(
                button: button,
                action: action,
                mods: mods(from: event.modifierFlags.rawValue),
                col: col,
                row: row,
                reportingMode: reportingMode
            )
        }
    #endif
}
