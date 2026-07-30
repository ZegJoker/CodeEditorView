import Foundation
import CodeEditorCore

/// A caret or selection expressed as line/column plus UTF-16 range.
public struct CursorPosition: Equatable, Hashable, Sendable, Codable {
    public var range: NSRange
    /// Zero-based line index.
    public var line: Int
    /// Zero-based UTF-16 column within the line.
    public var column: Int

    public init(range: NSRange, line: Int, column: Int) {
        self.range = range
        self.line = line
        self.column = column
    }

    public var isEmpty: Bool { range.length == 0 }

    public static func from(range: NSRange, line: Int, column: Int) -> CursorPosition {
        CursorPosition(range: range, line: line, column: column)
    }

    public static func from<Payload: LinePayload>(range: NSRange, lineIndex: LineIndex<Payload>) -> CursorPosition {
        if let line = lineIndex.line(atUTF16Offset: range.location) {
            return CursorPosition(
                range: range,
                line: line.index,
                column: max(0, range.location - line.utf16Offset)
            )
        }
        return CursorPosition(range: range, line: 0, column: range.location)
    }
}

// Codable for NSRange via location/length is not automatic on all SDKs — provide explicit coding.
extension CursorPosition {
    enum CodingKeys: String, CodingKey {
        case location, length, line, column
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let location = try container.decode(Int.self, forKey: .location)
        let length = try container.decode(Int.self, forKey: .length)
        let line = try container.decode(Int.self, forKey: .line)
        let column = try container.decode(Int.self, forKey: .column)
        self.init(range: NSRange(location: location, length: length), line: line, column: column)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range.location, forKey: .location)
        try container.encode(range.length, forKey: .length)
        try container.encode(line, forKey: .line)
        try container.encode(column, forKey: .column)
    }
}
