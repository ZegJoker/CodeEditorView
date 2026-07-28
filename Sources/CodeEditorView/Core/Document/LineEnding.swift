import Foundation

/// Supported newline styles for code documents.
public enum LineEnding: String, Sendable, Hashable, CaseIterable {
    case lineFeed = "\n"
    case carriageReturn = "\r"
    case carriageReturnLineFeed = "\r\n"

    public var length: Int { rawValue.utf16.count }

    /// Detects the dominant line ending by sampling early lines of `string`.
    ///
    /// Scans UTF-16 units so `"\\r\\n"` is not collapsed into a single Swift `Character`.
    public static func detect(in string: String, sampleLimit: Int = 50) -> LineEnding {
        var lf = 0
        var cr = 0
        var crlf = 0
        var examined = 0

        let utf16 = string.utf16
        var index = utf16.startIndex
        while index < utf16.endIndex, examined < sampleLimit {
            let unit = utf16[index]
            if unit == 0x0D {
                let next = utf16.index(after: index)
                if next < utf16.endIndex, utf16[next] == 0x0A {
                    crlf += 1
                    index = utf16.index(after: next)
                } else {
                    cr += 1
                    index = next
                }
                examined += 1
            } else if unit == 0x0A {
                lf += 1
                examined += 1
                index = utf16.index(after: index)
            } else {
                index = utf16.index(after: index)
            }
        }

        if crlf >= lf, crlf >= cr, crlf > 0 { return .carriageReturnLineFeed }
        if cr > lf, cr > 0 { return .carriageReturn }
        return .lineFeed
    }
}
