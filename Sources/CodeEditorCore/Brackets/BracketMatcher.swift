import Foundation

/// Finds matching bracket ranges around a UTF-16 caret offset.
public enum BracketMatcher {
    public struct Match: Equatable, Sendable {
        public var open: NSRange
        public var close: NSRange

        public init(open: NSRange, close: NSRange) {
            self.open = open
            self.close = close
        }
    }

    /// Looks for a bracket immediately before or at `offset` and returns both pair ranges.
    public static func match(aroundUTF16Offset offset: Int, in string: String) -> Match? {
        let ns = string as NSString
        let length = ns.length
        guard length > 0 else { return nil }

        // Prefer character immediately before caret (typing position), then at caret.
        let candidates = [offset - 1, offset].filter { $0 >= 0 && $0 < length }
        for location in candidates {
            guard let character = character(at: location, in: ns),
                  let mate = BracketPairs.mate(for: character) else {
                continue
            }
            if BracketPairs.isOpening(character) {
                if let close = scanForward(
                    from: location + 1,
                    open: character,
                    close: mate,
                    in: ns
                ) {
                    return Match(
                        open: NSRange(location: location, length: 1),
                        close: NSRange(location: close, length: 1)
                    )
                }
            } else if BracketPairs.isClosing(character) {
                if let open = scanBackward(
                    from: location - 1,
                    open: mate,
                    close: character,
                    in: ns
                ) {
                    return Match(
                        open: NSRange(location: open, length: 1),
                        close: NSRange(location: location, length: 1)
                    )
                }
            }
        }
        return nil
    }

    private static func scanForward(
        from start: Int,
        open: Character,
        close: Character,
        in ns: NSString
    ) -> Int? {
        var depth = 1
        var index = start
        let length = ns.length
        while index < length {
            guard let ch = character(at: index, in: ns) else {
                index += 1
                continue
            }
            if ch == open {
                depth += 1
            } else if ch == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func scanBackward(
        from start: Int,
        open: Character,
        close: Character,
        in ns: NSString
    ) -> Int? {
        var depth = 1
        var index = start
        while index >= 0 {
            guard let ch = character(at: index, in: ns) else {
                index -= 1
                continue
            }
            if ch == close {
                depth += 1
            } else if ch == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }

    private static func character(at index: Int, in ns: NSString) -> Character? {
        guard index >= 0, index < ns.length else { return nil }
        let unit = ns.character(at: index)
        // Skip UTF-16 low surrogates; brackets are BMP code points.
        if unit >= 0xDC00 && unit <= 0xDFFF { return nil }
        guard let scalar = UnicodeScalar(unit) else { return nil }
        return Character(scalar)
    }
}
