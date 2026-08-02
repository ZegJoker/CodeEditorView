import Foundation

/// A document position expressed as a UTF-16 code unit offset from the start.
///
/// Matches `NSString` / `NSRange` indexing and Tree-sitter’s UTF-16 byte mode
/// (`offset * 2`). Prefer this over raw `Int` at public provider / event boundaries.
public struct TextPosition: Sendable, Codable, Hashable, Comparable {
    public let utf16Offset: Int

    public init(utf16Offset: Int) {
        self.utf16Offset = max(0, utf16Offset)
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.utf16Offset < rhs.utf16Offset
    }
}

/// A half-open UTF-16 range `[start, end)`.
public struct TextRange: Sendable, Codable, Hashable {
    public let start: TextPosition
    public let end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        if end.utf16Offset < start.utf16Offset {
            self.start = end
            self.end = start
        } else {
            self.start = start
            self.end = end
        }
    }

    public init(location: Int, length: Int) {
        let loc = max(0, location)
        let len = max(0, length)
        // DOC-N05: never trap/wrap on location+length overflow — fail closed to empty range.
        let (endOffset, overflow) = loc.addingReportingOverflow(len)
        if overflow {
            self.start = TextPosition(utf16Offset: 0)
            self.end = TextPosition(utf16Offset: 0)
            return
        }
        self.start = TextPosition(utf16Offset: loc)
        self.end = TextPosition(utf16Offset: endOffset)
    }

    public init(_ nsRange: NSRange) {
        self.init(location: nsRange.location, length: max(0, nsRange.length))
    }

    public var location: Int { start.utf16Offset }
    public var length: Int { end.utf16Offset - start.utf16Offset }
    /// Overflow-safe end offset (DOC-N05). Prefer this over `location + length`.
    public var endUTF16Offset: Int { end.utf16Offset }
    public var nsRange: NSRange {
        NSRange(location: location, length: length)
    }

    public var isEmpty: Bool { length == 0 }
}
