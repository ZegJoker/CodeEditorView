import Foundation

/// Physical key codes matching Ghostty's `GhosttyKey` / W3C UI Events `code` values
/// (TER-N04). Numeric raw values must stay aligned with `ghostty/vt/key/event.h`.
///
/// Production encoding goes through Ghostty's key encoder via `GhosttySessionController.encodeKey`;
/// these codes are the structured input surface — never a hand-built PTY byte map.
public enum GhosttyPhysicalKey: UInt32, Sendable, Hashable, CaseIterable {
    case unidentified = 0

    // Writing system (W3C §3.1.1)
    case backquote = 1
    case backslash = 2
    case bracketLeft = 3
    case bracketRight = 4
    case comma = 5
    case digit0 = 6
    case digit1 = 7
    case digit2 = 8
    case digit3 = 9
    case digit4 = 10
    case digit5 = 11
    case digit6 = 12
    case digit7 = 13
    case digit8 = 14
    case digit9 = 15
    case equal = 16
    case intlBackslash = 17
    case intlRo = 18
    case intlYen = 19
    case a = 20
    case b = 21
    case c = 22
    case d = 23
    case e = 24
    case f = 25
    case g = 26
    case h = 27
    case i = 28
    case j = 29
    case k = 30
    case l = 31
    case m = 32
    case n = 33
    case o = 34
    case p = 35
    case q = 36
    case r = 37
    case s = 38
    case t = 39
    case u = 40
    case v = 41
    case w = 42
    case x = 43
    case y = 44
    case z = 45
    case minus = 46
    case period = 47
    case quote = 48
    case semicolon = 49
    case slash = 50

    // Functional (W3C §3.1.2)
    case altLeft = 51
    case altRight = 52
    case backspace = 53
    case capsLock = 54
    case contextMenu = 55
    case controlLeft = 56
    case controlRight = 57
    case enter = 58
    case metaLeft = 59
    case metaRight = 60
    case shiftLeft = 61
    case shiftRight = 62
    case space = 63
    case tab = 64
    case convert = 65
    case kanaMode = 66
    case nonConvert = 67

    // Control pad (W3C §3.2)
    case delete = 68
    case end = 69
    case help = 70
    case home = 71
    case insert = 72
    case pageDown = 73
    case pageUp = 74

    // Arrow pad (W3C §3.3)
    case arrowDown = 75
    case arrowLeft = 76
    case arrowRight = 77
    case arrowUp = 78

    // Numpad (W3C §3.4) — partial surface for common keys
    case numLock = 79
    case numpad0 = 80
    case numpad1 = 81
    case numpad2 = 82
    case numpad3 = 83
    case numpad4 = 84
    case numpad5 = 85
    case numpad6 = 86
    case numpad7 = 87
    case numpad8 = 88
    case numpad9 = 89
    case numpadAdd = 90
    case numpadBackspace = 91
    case numpadClear = 92
    case numpadClearEntry = 93
    case numpadComma = 94
    case numpadDecimal = 95
    case numpadDivide = 96
    case numpadEnter = 97
    case numpadEqual = 98
    case numpadMemoryAdd = 99
    case numpadMemoryClear = 100
    case numpadMemoryRecall = 101
    case numpadMemoryStore = 102
    case numpadMemorySubtract = 103
    case numpadMultiply = 104
    case numpadParenLeft = 105
    case numpadParenRight = 106
    case numpadSubtract = 107
    case numpadSeparator = 108
    case numpadUp = 109
    case numpadDown = 110
    case numpadRight = 111
    case numpadLeft = 112
    case numpadBegin = 113
    case numpadHome = 114
    case numpadEnd = 115
    case numpadInsert = 116
    case numpadDelete = 117
    case numpadPageUp = 118
    case numpadPageDown = 119

    // Function section (W3C §3.5)
    case escape = 120
    case f1 = 121
    case f2 = 122
    case f3 = 123
    case f4 = 124
    case f5 = 125
    case f6 = 126
    case f7 = 127
    case f8 = 128
    case f9 = 129
    case f10 = 130
    case f11 = 131
    case f12 = 132
    case f13 = 133
    case f14 = 134
    case f15 = 135
    case f16 = 136
    case f17 = 137
    case f18 = 138
    case f19 = 139
    case f20 = 140
    case f21 = 141
    case f22 = 142
    case f23 = 143
    case f24 = 144
    case f25 = 145
    case fn = 146
    case fnLock = 147
    case printScreen = 148
    case scrollLock = 149
    case pause = 150

    /// Default xterm normal-mode CSI/SS3 sequence for this key (test oracle / docs).
    /// Production encoding always uses Ghostty's key encoder when linked (TER-N04).
    public var defaultNormalModeSequence: Data? {
        switch self {
        case .arrowUp: return Data("\u{1b}[A".utf8)
        case .arrowDown: return Data("\u{1b}[B".utf8)
        case .arrowRight: return Data("\u{1b}[C".utf8)
        case .arrowLeft: return Data("\u{1b}[D".utf8)
        case .home: return Data("\u{1b}[H".utf8)
        case .end: return Data("\u{1b}[F".utf8)
        case .insert: return Data("\u{1b}[2~".utf8)
        case .delete: return Data("\u{1b}[3~".utf8)
        case .pageUp: return Data("\u{1b}[5~".utf8)
        case .pageDown: return Data("\u{1b}[6~".utf8)
        case .f1: return Data("\u{1b}OP".utf8)
        case .f2: return Data("\u{1b}OQ".utf8)
        case .f3: return Data("\u{1b}OR".utf8)
        case .f4: return Data("\u{1b}OS".utf8)
        case .f5: return Data("\u{1b}[15~".utf8)
        case .f6: return Data("\u{1b}[17~".utf8)
        case .f7: return Data("\u{1b}[18~".utf8)
        case .f8: return Data("\u{1b}[19~".utf8)
        case .f9: return Data("\u{1b}[20~".utf8)
        case .f10: return Data("\u{1b}[21~".utf8)
        case .f11: return Data("\u{1b}[23~".utf8)
        case .f12: return Data("\u{1b}[24~".utf8)
        case .escape: return Data([0x1b])
        case .tab: return Data([0x09])
        case .enter: return Data([0x0d])
        case .backspace: return Data([0x7f])
        case .space: return Data([0x20])
        default: return nil
        }
    }

    /// Application cursor mode sequences (DECCKM).
    public var defaultApplicationCursorSequence: Data? {
        switch self {
        case .arrowUp: return Data("\u{1b}OA".utf8)
        case .arrowDown: return Data("\u{1b}OB".utf8)
        case .arrowRight: return Data("\u{1b}OC".utf8)
        case .arrowLeft: return Data("\u{1b}OD".utf8)
        case .home: return Data("\u{1b}OH".utf8)
        case .end: return Data("\u{1b}OF".utf8)
        default: return defaultNormalModeSequence
        }
    }
}
