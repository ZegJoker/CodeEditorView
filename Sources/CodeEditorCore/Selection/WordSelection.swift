import Foundation

/// Word / subword navigation modes for code editors (UI-004 / audit §11.5).
public enum WordNavigationMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Alphanumeric + underscore runs (classic code identifier).
    case codeIdentifier
    /// camelCase / snake_case / ACRONYM-aware subword boundaries.
    case codeSubword
    /// Unicode alphabetic runs (closer to system word boundaries).
    case unicodeWord
}

/// Pure helpers for double-click word selection and subword navigation.
public enum WordSelection: Sendable {
    /// Word range at `offset` using ``WordNavigationMode/codeIdentifier``.
    public static func range(atUTF16Offset offset: Int, in document: String) -> NSRange {
        range(atUTF16Offset: offset, in: document, mode: .codeIdentifier)
    }

    public static func range(
        atUTF16Offset offset: Int,
        in document: String,
        mode: WordNavigationMode
    ) -> NSRange {
        switch mode {
        case .codeIdentifier:
            return identifierRange(atUTF16Offset: offset, in: document)
        case .unicodeWord:
            return unicodeWordRange(atUTF16Offset: offset, in: document)
        case .codeSubword:
            return subwordRange(atUTF16Offset: offset, in: document)
        }
    }

    /// Move caret by one word/subword in `direction` (+1 forward, −1 backward).
    public static func boundary(
        fromUTF16Offset offset: Int,
        in document: String,
        direction: Int,
        mode: WordNavigationMode
    ) -> Int {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return 0 }
        var o = min(max(0, offset), length)
        if direction >= 0 {
            if o >= length { return length }
            let r = range(atUTF16Offset: o, in: document, mode: mode)
            if r.length > 0, o < r.location + r.length {
                return r.location + r.length
            }
            // Skip non-word and take next.
            while o < length, !isSignificant(ns.character(at: o), mode: mode) {
                o += 1
            }
            let next = range(atUTF16Offset: min(o, length - 1), in: document, mode: mode)
            return next.location + next.length
        } else {
            if o <= 0 { return 0 }
            let probe = o - 1
            let r = range(atUTF16Offset: probe, in: document, mode: mode)
            if r.length > 0, o > r.location {
                return r.location
            }
            var p = probe
            while p > 0, !isSignificant(ns.character(at: p), mode: mode) {
                p -= 1
            }
            let prev = range(atUTF16Offset: p, in: document, mode: mode)
            return prev.location
        }
    }

    // MARK: - Identifier

    private static func identifierRange(atUTF16Offset offset: Int, in document: String) -> NSRange {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, offset), length)

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

    // MARK: - Unicode word

    private static func unicodeWordRange(atUTF16Offset offset: Int, in document: String) -> NSRange {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, offset), length)
        var probe = min(clamped, length - 1)
        if probe > 0, isWhitespace(ns.character(at: probe)), !isWhitespace(ns.character(at: probe - 1)) {
            probe -= 1
        }
        guard probe < length else { return NSRange(location: length, length: 0) }
        if isWhitespace(ns.character(at: probe)) {
            return ns.rangeOfComposedCharacterSequences(for: NSRange(location: probe, length: 1))
        }
        var start = probe
        while start > 0, isUnicodeWordChar(ns.character(at: start - 1)) {
            start -= 1
        }
        var end = probe + 1
        while end < length, isUnicodeWordChar(ns.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Subword (camel / snake / acronym)

    private static func subwordRange(atUTF16Offset offset: Int, in document: String) -> NSRange {
        let id = identifierRange(atUTF16Offset: offset, in: document)
        guard id.length > 1 else { return id }
        let ns = document as NSString
        let word = ns.substring(with: id)
        let segs = subwordSegments(word)
        let local = min(max(0, offset - id.location), (word as NSString).length)
        var cursor = 0
        for seg in segs {
            let next = cursor + (seg as NSString).length
            if local < next || (local == next && next == (word as NSString).length) {
                return NSRange(location: id.location + cursor, length: (seg as NSString).length)
            }
            if local >= cursor, local < next {
                return NSRange(location: id.location + cursor, length: (seg as NSString).length)
            }
            cursor = next
        }
        return id
    }

    /// Split an identifier into subword segments (public for tests).
    public static func subwordSegments(_ identifier: String) -> [String] {
        if identifier.isEmpty { return [] }
        // Snake / kebab
        if identifier.contains("_") || identifier.contains("-") {
            var parts: [String] = []
            var current = ""
            for ch in identifier {
                if ch == "_" || ch == "-" {
                    if !current.isEmpty {
                        parts.append(current)
                        current = ""
                    }
                    parts.append(String(ch))
                } else {
                    current.append(ch)
                }
            }
            if !current.isEmpty { parts.append(current) }
            return parts.filter { !$0.isEmpty }
        }

        // camelCase / PascalCase / ACRONYMS
        let scalars = Array(identifier.unicodeScalars)
        var parts: [String] = []
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if CharacterSet.decimalDigits.contains(s) {
                var j = i
                while j < scalars.count, CharacterSet.decimalDigits.contains(scalars[j]) { j += 1 }
                parts.append(String(String.UnicodeScalarView(scalars[i..<j])))
                i = j
                continue
            }
            if CharacterSet.uppercaseLetters.contains(s) {
                var j = i + 1
                // ACRONYM: HTTPServer → HTTP + Server
                while j < scalars.count, CharacterSet.uppercaseLetters.contains(scalars[j]) {
                    j += 1
                }
                if j < scalars.count, CharacterSet.lowercaseLetters.contains(scalars[j]), j - i > 1 {
                    j -= 1
                }
                while j < scalars.count, CharacterSet.lowercaseLetters.contains(scalars[j]) {
                    j += 1
                }
                parts.append(String(String.UnicodeScalarView(scalars[i..<j])))
                i = j
                continue
            }
            var j = i + 1
            while j < scalars.count,
                !CharacterSet.uppercaseLetters.contains(scalars[j]),
                !CharacterSet.decimalDigits.contains(scalars[j])
            {
                j += 1
            }
            parts.append(String(String.UnicodeScalarView(scalars[i..<j])))
            i = j
        }
        return parts.filter { !$0.isEmpty }
    }

    // MARK: - Char classes

    private static func isSignificant(_ unit: unichar, mode: WordNavigationMode) -> Bool {
        switch mode {
        case .codeIdentifier, .codeSubword: return isWordChar(unit)
        case .unicodeWord: return isUnicodeWordChar(unit)
        }
    }

    private static func isWordChar(_ unit: unichar) -> Bool {
        if unit == 0x5F { return true }  // _
        if unit >= 0x30 && unit <= 0x39 { return true }
        if unit >= 0x41 && unit <= 0x5A { return true }
        if unit >= 0x61 && unit <= 0x7A { return true }
        if let scalar = UnicodeScalar(unit) {
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
        return false
    }

    private static func isUnicodeWordChar(_ unit: unichar) -> Bool {
        if isWhitespace(unit) { return false }
        if let scalar = UnicodeScalar(unit) {
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || unit == 0x5F
        }
        return false
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
            || (UnicodeScalar(unit)?.properties.isWhitespace ?? false)
    }
}
