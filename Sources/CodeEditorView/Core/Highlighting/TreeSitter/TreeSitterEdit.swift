import Foundation
import SwiftTreeSitter

/// Builds tree-sitter ``InputEdit`` values from UTF-16 document edits.
///
/// SwiftTreeSitter defaults to UTF-16, where each UTF-16 code unit is 2 bytes.
public enum TreeSitterEdit {
    /// - Parameters:
    ///   - range: Replaced UTF-16 range in the **pre-edit** document.
    ///   - delta: `insertedUTF16Count - range.length`.
    ///   - oldSource: Document text before the edit.
    ///   - newSource: Document text after the edit.
    public static func make(
        range: NSRange,
        delta: Int,
        oldSource: String,
        newSource: String
    ) -> InputEdit {
        let oldNS = oldSource as NSString
        let newNS = newSource as NSString
        let oldLength = oldNS.length
        let newLength = newNS.length

        let start = max(0, min(range.location, oldLength))
        let oldEnd = max(start, min(range.location + range.length, oldLength))
        let inserted = max(0, (range.length) + delta)
        let newEnd = max(start, min(start + inserted, newLength))

        let startByte = start * 2
        let oldEndByte = oldEnd * 2
        let newEndByte = newEnd * 2

        return InputEdit(
            startByte: startByte,
            oldEndByte: oldEndByte,
            newEndByte: newEndByte,
            startPoint: point(atUTF16Offset: start, in: oldNS),
            oldEndPoint: point(atUTF16Offset: oldEnd, in: oldNS),
            newEndPoint: point(atUTF16Offset: newEnd, in: newNS)
        )
    }

    /// UTF-16 offset → tree-sitter `Point` (row, column-in-bytes on that row).
    public static func point(atUTF16Offset offset: Int, in string: NSString) -> Point {
        let length = string.length
        let clamped = max(0, min(offset, length))
        if clamped == 0 { return .zero }

        var row = 0
        var lineStart = 0
        var i = 0
        while i < clamped {
            let unit = string.character(at: i)
            if unit == 0x0A { // \n
                row += 1
                lineStart = i + 1
            } else if unit == 0x0D { // \r or \r\n
                if i + 1 < length, string.character(at: i + 1) == 0x0A {
                    // Count the pair as one line break; point after \n.
                    if i + 1 < clamped {
                        row += 1
                        lineStart = i + 2
                        i += 2
                        continue
                    }
                } else {
                    row += 1
                    lineStart = i + 1
                }
            }
            i += 1
        }
        // Column is byte offset within the line (UTF-16 units * 2).
        let column = (clamped - lineStart) * 2
        return Point(row: row, column: column)
    }

    public static func indexSet(from tsRanges: [TSRange], documentLength: Int) -> IndexSet {
        var set = IndexSet()
        for tsRange in tsRanges {
            let ns = tsRange.bytes.range
            let start = max(0, min(ns.location, documentLength))
            let end = max(start, min(ns.location + ns.length, documentLength))
            if end > start {
                set.insert(integersIn: start..<end)
            }
        }
        return set
    }
}
