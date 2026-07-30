import Foundation

/// Built-in bracket pair definitions for matching and emphasis.
public enum BracketPairs: Sendable {
    public static let pairs: [(open: Character, close: Character)] = [
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
        ("<", ">"),
    ]

    public static var opening: Set<Character> {
        Set(pairs.map(\.open))
    }

    public static var closing: Set<Character> {
        Set(pairs.map(\.close))
    }

    public static func isOpening(_ character: Character) -> Bool {
        opening.contains(character)
    }

    public static func isClosing(_ character: Character) -> Bool {
        closing.contains(character)
    }

    public static func mate(for character: Character) -> Character? {
        for pair in pairs {
            if pair.open == character { return pair.close }
            if pair.close == character { return pair.open }
        }
        return nil
    }

    public static func isOpening(_ character: Character, mate: Character) -> Bool {
        pairs.contains { $0.open == character && $0.close == mate }
    }
}
