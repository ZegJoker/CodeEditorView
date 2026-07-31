import Foundation

/// Modifier flags for a key press (platform-neutral).
public struct KeyModifier: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifier(rawValue: 1 << 0)
    public static let shift = KeyModifier(rawValue: 1 << 1)
    public static let option = KeyModifier(rawValue: 1 << 2)
    public static let control = KeyModifier(rawValue: 1 << 3)
}

/// One physical key press with modifiers.
public struct KeyPress: Sendable, Codable, Hashable, CustomStringConvertible {
    /// Normalized key: `"a"`, `"tab"`, `"escape"`, `"up"`, `"return"`, `"space"`, `"["`, …
    public var key: String
    public var modifiers: KeyModifier

    public init(key: String, modifiers: KeyModifier = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

/// Simple binding or multi-step chord, with optional when-clause.
public struct Keybinding: Sendable, Codable, Hashable {
    public var chord: [KeyPress]
    public var when: ContextExpression

    public init(chord: [KeyPress], when: ContextExpression = .always) {
        self.chord = chord
        self.when = when
    }

    public init(key: String, modifiers: KeyModifier = [], when: ContextExpression = .always) {
        self.chord = [KeyPress(key: key, modifiers: modifiers)]
        self.when = when
    }

    public static func command(_ key: String, when: ContextExpression = .always) -> Keybinding {
        Keybinding(key: key, modifiers: .command, when: when)
    }
}

/// Origin layer for conflict resolution (higher raw value wins).
public enum KeybindingSource: Int, Sendable, Codable, Comparable, Hashable {
    case builtIn = 0
    case extensionModule = 1
    case host = 2
    case workspace = 3
    case user = 4

    public static func < (lhs: KeybindingSource, rhs: KeybindingSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Serializable user/host override.
public struct KeybindingOverride: Sendable, Codable, Hashable {
    public var commandID: CommandID
    public var keybinding: Keybinding
    public var source: KeybindingSource
    public var priority: Int

    public init(
        commandID: CommandID,
        keybinding: Keybinding,
        source: KeybindingSource = .user,
        priority: Int = 0
    ) {
        self.commandID = commandID
        self.keybinding = keybinding
        self.source = source
        self.priority = priority
    }
}
