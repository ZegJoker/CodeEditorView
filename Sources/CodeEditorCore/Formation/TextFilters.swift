import Foundation

/// Pure text-formation helpers (tab, auto-pairs, newline indent). No document ownership.
public enum TextFilters: Sendable {
    /// Characters that open an auto-pair and their closers.
    public static let autoPairs: [(open: Character, close: Character)] = [
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
        ("\"", "\""),
        ("'", "'"),
        ("`", "`"),
    ]

    public static func expandTab(indent: IndentOption) -> String {
        indent.string
    }

    /// Result of filtering a single-character insertion for auto-pair behavior.
    public struct AutoPairResult: Equatable, Sendable {
        /// Text to insert at the caret (may be two chars, e.g. `()`).
        public var insert: String
        /// If true, place caret between the pair after insert.
        public var placeCaretInside: Bool
        /// If true, do not insert; advance caret by 1 over the existing closer.
        public var skipOver: Bool

        public init(insert: String, placeCaretInside: Bool, skipOver: Bool = false) {
            self.insert = insert
            self.placeCaretInside = placeCaretInside
            self.skipOver = skipOver
        }
    }

    /// Filters a single-character typed insert for auto-pair behavior.
    public static func autoPair(
        inserted: String,
        nextCharacter: Character?
    ) -> AutoPairResult? {
        guard inserted.count == 1, let ch = inserted.first else { return nil }

        // Skip over an existing matching closer when the user types it again.
        if let next = nextCharacter {
            for pair in autoPairs where pair.close == ch && next == pair.close {
                // Asymmetric: only when typing the closer.
                if pair.open != pair.close {
                    return AutoPairResult(insert: "", placeCaretInside: false, skipOver: true)
                }
                // Symmetric quotes: skip when next is already the same quote.
                return AutoPairResult(insert: "", placeCaretInside: false, skipOver: true)
            }
        }

        // Insert both sides for openers.
        for pair in autoPairs where pair.open == ch {
            // Symmetric quotes: only pair when next is not alphanumeric (avoid word interior).
            if pair.open == pair.close {
                if let next = nextCharacter, next.isLetter || next.isNumber {
                    return nil
                }
            }
            let insert = String(pair.open) + String(pair.close)
            return AutoPairResult(insert: insert, placeCaretInside: true, skipOver: false)
        }

        return nil
    }

    /// Leading whitespace (spaces/tabs) at the start of `line`.
    public static func leadingWhitespace(ofLine line: String) -> String {
        var ws = ""
        for ch in line {
            if ch == " " || ch == "\t" {
                ws.append(ch)
            } else {
                break
            }
        }
        return ws
    }

    /// Indent prefix for a newline after `lineText` (text on the line before the caret).
    public static func indentPrefix(forNewlineAfter lineText: String, indent: IndentOption) -> String {
        let base = leadingWhitespace(ofLine: lineText)
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("{") || trimmed.hasSuffix(":") {
            return base + indent.string
        }
        return base
    }

    /// Result of computing a newline insertion (possibly splitting a brace pair).
    public struct NewlineInsertion: Equatable, Sendable {
        /// Full string to insert at the caret (includes leading `\n`).
        public var payload: String
        /// UTF-16 offset from the start of `payload` where the caret should land.
        public var caretOffsetInPayload: Int

        public init(payload: String, caretOffsetInPayload: Int) {
            self.payload = payload
            self.caretOffsetInPayload = caretOffsetInPayload
        }
    }

    /// Builds the text inserted when the user presses Return.
    ///
    /// - When the caret is between a matching pair like `{|}`, produces:
    ///   ```
    ///   {
    ///       |
    ///   }
    ///   ```
    ///   so the closer keeps the *base* indent (not the inner indent).
    /// - Otherwise: `\n` + indent prefix (extra level after `{` / `:`).
    public static func newlineInsertion(
        lineTextBeforeCaret: String,
        nextCharacter: Character?,
        indent: IndentOption
    ) -> NewlineInsertion {
        let base = leadingWhitespace(ofLine: lineTextBeforeCaret)
        let trimmed = lineTextBeforeCaret.trimmingCharacters(in: .whitespaces)
        let opensBlock =
            trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(")
            || trimmed.hasSuffix(":")

        // Split `{|}` / `[|]` / `(|)` so the closer is not dragged onto the indented middle line.
        if let next = nextCharacter,
            isClosingPair(next),
            opensBlock || pairOpen(for: next).map({ lineTextBeforeCaret.hasSuffix(String($0)) }) == true
        {
            let inner = base + indent.string
            // "\n" + inner + "\n" + base  → caret after inner
            let payload = "\n" + inner + "\n" + base
            let caret = 1 + inner.utf16.count
            return NewlineInsertion(payload: payload, caretOffsetInPayload: caret)
        }

        let prefix = opensBlock ? base + indent.string : base
        let payload = "\n" + prefix
        return NewlineInsertion(payload: payload, caretOffsetInPayload: payload.utf16.count)
    }

    public static func isClosingPair(_ ch: Character) -> Bool {
        autoPairs.contains { $0.close == ch }
    }

    public static func pairOpen(for close: Character) -> Character? {
        autoPairs.first { $0.close == close }?.open
    }

    /// If `location` is at the start of a line, returns the UTF-16 range of the preceding
    /// line ending (`\n` or `\r\n`); otherwise `nil`.
    public static func lineEndingRangeBefore(
        location: Int,
        in document: String
    ) -> NSRange? {
        guard location > 0 else { return nil }
        let ns = document as NSString
        let prev = ns.character(at: location - 1)
        if prev == 0x0A {  // \n
            if location >= 2, ns.character(at: location - 2) == 0x0D {
                return NSRange(location: location - 2, length: 2)
            }
            return NSRange(location: location - 1, length: 1)
        }
        if prev == 0x0D {
            return NSRange(location: location - 1, length: 1)
        }
        return nil
    }

    /// Whether `location` is at the start of a logical line (column 0).
    public static func isAtLineStart(location: Int, in document: String) -> Bool {
        if location <= 0 { return true }
        let ns = document as NSString
        let prev = ns.character(at: location - 1)
        return prev == 0x0A || prev == 0x0D
    }

    /// Range of leading spaces/tabs on the line containing `location` (excludes the line ending).
    public static func leadingWhitespaceRange(
        containing location: Int,
        in document: String
    ) -> NSRange? {
        let ns = document as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        let probe = min(max(0, location), length - 1)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: probe, length: 0)
        )
        var end = lineStart
        while end < contentsEnd {
            let ch = ns.character(at: end)
            if ch == 0x20 || ch == 0x09 {
                end += 1
            } else {
                break
            }
        }
        let len = end - lineStart
        guard len > 0 else { return nil }
        return NSRange(location: lineStart, length: len)
    }

    /// Range to delete for backward-delete of a single empty caret.
    ///
    /// Mirrors [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) +
    /// [CodeEditSourceEditor `DeleteWhitespaceFilter`](https://github.com/CodeEditApp/CodeEditSourceEditor):
    /// 1. Default: delete the previous composed character (joining lines when at column 0 by removing
    ///    the preceding line ending — caret stays on the *previous* line).
    /// 2. When that character lies in the line's leading indent spaces: delete one whole indent unit
    ///    from the end of the leading whitespace (not a single space).
    ///
    /// Importantly, a blank line is removed by deleting the **previous** `\n`, not the blank line's
    /// own terminator — so the caret ends after `{` rather than jumping to column 0 of `}`.
    public static func deleteBackwardRange(
        caret: Int,
        in document: String,
        indent: IndentOption = .spaces(count: 4)
    ) -> NSRange? {
        let ns = document as NSString
        let length = ns.length
        guard caret > 0, caret <= length else { return nil }

        // CodeEditTextView: extend selection by one composed character backward.
        let baseRange: NSRange
        if let ending = lineEndingRangeBefore(location: caret, in: document),
            ending.location + ending.length == caret
        {
            baseRange = ending
        } else {
            baseRange = ns.rangeOfComposedCharacterSequences(
                for: NSRange(location: caret - 1, length: 1)
            )
        }

        // CodeEditSourceEditor DeleteWhitespaceFilter: collapse indent units.
        // Only for space indents; only when the single deleted unit sits in leading whitespace.
        if case .spaces(let indentLength) = indent,
            indentLength > 0,
            baseRange.length == 1,
            let leading = leadingWhitespaceRange(containing: baseRange.location, in: document),
            baseRange.location >= leading.location,
            baseRange.location < leading.location + leading.length
        {
            var numberOfExtraSpaces = leading.length % indentLength
            if numberOfExtraSpaces == 0 {
                numberOfExtraSpaces = indentLength
            }
            let deleteStart = leading.location + leading.length - numberOfExtraSpaces
            if deleteStart >= leading.location {
                return NSRange(location: deleteStart, length: numberOfExtraSpaces)
            }
        }

        return baseRange
    }

    /// Strip one indent unit from the start of `line` if present.
    public static func outdentLine(_ line: String, indent: IndentOption) -> String {
        let unit = indent.string
        if !unit.isEmpty, line.hasPrefix(unit) {
            return String(line.dropFirst(unit.count))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        let maxStrip: Int
        switch indent {
        case .spaces(let count): maxStrip = max(1, count)
        case .tab: maxStrip = 1
        }
        var drop = 0
        for ch in line {
            if ch == " ", drop < maxStrip {
                drop += 1
            } else {
                break
            }
        }
        if drop > 0 {
            return String(line.dropFirst(drop))
        }
        return line
    }

    public static func indentLine(_ line: String, indent: IndentOption) -> String {
        indent.string + line
    }
}
