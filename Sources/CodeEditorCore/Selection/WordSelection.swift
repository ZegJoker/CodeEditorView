import Foundation

/// Pure helpers for double-click word selection (code-oriented identifiers).
public enum WordSelection: Sendable {
    /// Word range at `offset`: alphanumeric + `_`, else a single composed character.
    public static func range(atUTF16Offset offset: Int, in document: String) -> NSRange {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, offset), length)

        // Prefer the character before the caret only at EOF or on whitespace after a word
        // (so double-click just after `hello|` selects hello). Punctuation stays on itself.
        var probe = clamped
        if probe == length {
            probe = max(0, probe - 1)
        } else if probe > 0,
                  isWhitespace(ns.character(at: probe)),
                  isWordChar(ns.character(at: probe - 1))
        {
            probe -= 1
        }
        guard probe < length, isWordChar(ns.character(at: probe)) else {
            if clamped >= length {
                return NSRange(location: length, length: 0)
            }
            return ns.rangeOfComposedCharacterSequences(for: NSRange(location: clamped, length: 1))
        }

        var start = probe
        while start > 0, isWordChar(ns.character(at: start - 1)) {
            start -= 1
        }
        var end = probe + 1
        while end < length, isWordChar(ns.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isWordChar(_ unit: unichar) -> Bool {
        if unit == 0x5F { return true } // _
        if unit >= 0x30 && unit <= 0x39 { return true }
        if unit >= 0x41 && unit <= 0x5A { return true }
        if unit >= 0x61 && unit <= 0x7A { return true }
        if let scalar = UnicodeScalar(unit) {
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
        return false
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
            || (UnicodeScalar(unit)?.properties.isWhitespace ?? false)
    }
}
