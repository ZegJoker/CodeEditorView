import Foundation
import CodeEditorCommands

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public extension KeyPress {
    /// Maps an AppKit key event to a platform-neutral press.
    init?(nsEvent event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifier = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        let key: String
        switch event.keyCode {
        case 53: key = "escape"
        case 48: key = "tab"
        case 36, 76: key = "return"
        case 51: key = "backspace"
        case 117: key = "delete"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 49: key = "space"
        default:
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            guard let first = chars.first else { return nil }
            key = String(first)
        }
        self.init(key: key, modifiers: modifiers)
    }
}
#endif
