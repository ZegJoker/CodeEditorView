import CoreGraphics
import Foundation

extension LineIndex {
    /// Splits `string` into lines (keeping line terminators on each line) and rebuilds the index.
    public static func build(
        from string: String,
        estimatedLineHeight: CGFloat,
        makePayload: (Int) -> Payload
    ) -> LineIndex<Payload> {
        let index = LineIndex<Payload>()
        var lines: [(Payload, LineMetrics)] = []
        lines.reserveCapacity(max(1, string.utf16.count / 40))

        let utf16 = string.utf16
        var start = utf16.startIndex
        var lineNumber = 0

        while start < utf16.endIndex {
            var end = start
            var foundTerminator = false
            while end < utf16.endIndex {
                let unit = utf16[end]
                if unit == 0x0A {  // \n
                    end = utf16.index(after: end)
                    foundTerminator = true
                    break
                }
                if unit == 0x0D {  // \r
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
            // Empty final line after trailing newline.
            if length == 0, !foundTerminator, start == utf16.endIndex {
                break
            }

            let metrics = LineMetrics(utf16Length: max(length, 0), height: estimatedLineHeight)
            lines.append((makePayload(lineNumber), metrics))
            lineNumber += 1
            start = end
        }

        if lines.isEmpty {
            lines.append((makePayload(0), LineMetrics(utf16Length: 0, height: estimatedLineHeight)))
        } else {
            // Ensure a trailing empty line when the *document* ends with a newline (caret after last \n).
            let last = lines[lines.count - 1]
            let lastLen = last.1.utf16Length
            if lastLen > 0 {
                let ns = string as NSString
                let lastRange = NSRange(location: ns.length - lastLen, length: lastLen)
                let lastString = ns.substring(with: lastRange)
                if lastString.hasSuffix("\n") || lastString.hasSuffix("\r") {
                    lines.append((makePayload(lineNumber), LineMetrics(utf16Length: 0, height: estimatedLineHeight)))
                }
            }
        }

        index.rebuild(lines: lines)
        return index
    }

    /// Convenience using ``LineMetrics/splitLines`` with trailing empty-line semantics.
    public static func buildUsingSplitLines(
        from string: String,
        estimatedLineHeight: CGFloat,
        makePayload: (Int) -> Payload
    ) -> LineIndex<Payload> {
        let metrics = LineMetrics.splitLines(
            in: string,
            estimatedHeight: estimatedLineHeight,
            includeTrailingEmptyLine: true
        )
        let index = LineIndex<Payload>()
        let lines = metrics.enumerated().map { ($0.offset, $0.element) }.map { i, m in
            (makePayload(i), m)
        }
        index.rebuild(lines: lines)
        return index
    }
}
