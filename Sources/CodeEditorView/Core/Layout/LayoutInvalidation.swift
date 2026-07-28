import Foundation

/// Computes which logical lines must be rebuilt after a document edit.
public enum LayoutInvalidation {
    /// Line index range (inclusive start, exclusive end) covering `editRange` before the edit,
    /// expanded by one line of context when possible.
    public static func dirtyLineIndexRange(
        editRange: NSRange,
        lineCount: Int,
        lineAtOffset: (Int) -> Int?
    ) -> Range<Int> {
        guard lineCount > 0 else { return 0..<0 }
        let startOffset = editRange.location
        let endOffset = max(editRange.location, editRange.location + max(0, editRange.length) - 1)
        let startLine = lineAtOffset(startOffset) ?? 0
        let endLine = lineAtOffset(endOffset) ?? startLine
        let lower = max(0, min(startLine, endLine))
        let upper = min(lineCount, max(startLine, endLine) + 1)
        return lower..<max(lower + 1, upper)
    }

    /// Splits a UTF-16 string slice into line metrics (including terminators), using estimated height.
    public static func splitLines(in string: String, estimatedHeight: CGFloat) -> [LineMetrics] {
        let utf16 = string.utf16
        var metrics: [LineMetrics] = []
        var start = utf16.startIndex

        while start < utf16.endIndex {
            var end = start
            var foundTerminator = false
            while end < utf16.endIndex {
                let unit = utf16[end]
                if unit == 0x0A {
                    end = utf16.index(after: end)
                    foundTerminator = true
                    break
                }
                if unit == 0x0D {
                    end = utf16.index(after: end)
                    if end < utf16.endIndex, utf16[end] == 0x0A {
                        end = utf16.index(after: end)
                    }
                    foundTerminator = true
                    break
                }
                end = utf16.index(after: end)
            }
            let length = utf16.distance(from: start, to: end)
            if length == 0, !foundTerminator, start == utf16.endIndex { break }
            metrics.append(LineMetrics(utf16Length: max(length, 0), height: estimatedHeight))
            start = end
        }

        if metrics.isEmpty {
            metrics.append(LineMetrics(utf16Length: 0, height: estimatedHeight))
        } else if let last = metrics.last, last.utf16Length > 0 {
            let ns = string as NSString
            let lastRange = NSRange(location: ns.length - last.utf16Length, length: last.utf16Length)
            let lastString = ns.substring(with: lastRange)
            if lastString.hasSuffix("\n") || lastString.hasSuffix("\r") {
                metrics.append(LineMetrics(utf16Length: 0, height: estimatedHeight))
            }
        }
        return metrics
    }
}
