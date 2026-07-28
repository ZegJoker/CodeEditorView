import Foundation

/// Builds fold ranges for a document from a ``LineFoldProvider`` (CESE calculator, `@MainActor`).
@MainActor
public enum LineFoldCalculator {
    /// Scan the whole document and produce raw folds.
    ///
    /// Uses the provider’s per-line start/end markers (depth stack), then **snaps** each fold
    /// to whole-line boundaries so collapsing always hides complete body lines (Xcode-like).
    public static func buildRawFolds(
        context: LineFoldProviderContext,
        lineRanges: [(lineNumber: Int, range: NSRange)],
        provider: any LineFoldProvider
    ) -> [LineFoldStorage.RawFold] {
        // Line-based indent folds only (enforces min body size, bubble at first body line).
        // Depth-stack fallback is not used — it reintroduced single-line folds.
        return buildIndentLineFolds(context: context, lineRanges: lineRanges)
    }

    // MARK: - Line-based indent folds (primary)

    /// Xcode-style: line `i` is foldable when the next non-blank line is more indented.
    /// The fold covers whole lines from `i+1` through the last line still deeper than `i`.
    public static func buildIndentLineFolds(
        context: LineFoldProviderContext,
        lineRanges: [(lineNumber: Int, range: NSRange)]
    ) -> [LineFoldStorage.RawFold] {
        let text = context.nsDocument
        guard !lineRanges.isEmpty else { return [] }

        struct LineInfo {
            var number: Int
            var range: NSRange
            var indent: Int
            var isBlank: Bool
            var contentEnd: Int
        }

        let infos: [LineInfo] = lineRanges.map { line in
            let indent = leadingWhitespaceLength(in: line.range, text: text)
            let isBlank = indent >= line.range.length
                || isWhitespaceOnly(line.range, text: text)
            return LineInfo(
                number: line.lineNumber,
                range: line.range,
                indent: isBlank ? -1 : indent,
                isBlank: isBlank,
                contentEnd: contentEndOffset(in: line.range, text: text)
            )
        }

        var folds: [LineFoldStorage.RawFold] = []

        for i in 0..<infos.count {
            let header = infos[i]
            guard !header.isBlank else { continue }

            // Find next non-blank line.
            var j = i + 1
            while j < infos.count, infos[j].isBlank { j += 1 }
            guard j < infos.count, infos[j].indent > header.indent else { continue }

            // Body runs until a non-blank line with indent <= header (the closer / sibling).
            var endLineIndex = j
            var k = j
            while k < infos.count {
                if !infos[k].isBlank {
                    if infos[k].indent <= header.indent {
                        break
                    }
                    endLineIndex = k
                }
                k += 1
            }

            // Count non-blank body lines — single-line bodies are not foldable.
            var bodyLineCount = 0
            for t in j...endLineIndex where !infos[t].isBlank {
                bodyLineCount += 1
            }
            guard bodyLineCount >= 2 else { continue }

            // Bubble sits at the **start of the first folded line**, not after `{` on the header.
            // Range covers whole body lines through the last body line’s terminator.
            let rangeStart = infos[j].range.location
            let rangeEnd = infos[endLineIndex].range.location + infos[endLineIndex].range.length
            guard rangeStart < rangeEnd else { continue }

            // Depth: indent of body (relative nesting).
            let depth = max(1, infos[j].indent)
            folds.append(LineFoldStorage.RawFold(depth: depth, range: rangeStart..<rangeEnd))
        }

        return folds
    }

    // MARK: - Depth-stack fallback (provider-driven)

    private static func buildDepthStackFolds(
        context: LineFoldProviderContext,
        lineRanges: [(lineNumber: Int, range: NSRange)],
        provider: any LineFoldProvider
    ) -> [LineFoldStorage.RawFold] {
        var foldCache: [LineFoldStorage.RawFold] = []
        var openFolds: [Int: LineFoldStorage.RawFold] = [:]
        var currentDepth = 0

        for line in lineRanges {
            let infos = provider.foldLevelAtLine(
                lineNumber: line.lineNumber,
                lineRange: line.range,
                previousDepth: currentDepth,
                context: context
            )
            for info in infos {
                if info.depth > currentDepth {
                    let newFold = LineFoldStorage.RawFold(
                        depth: info.depth,
                        range: info.rangeIndice..<info.rangeIndice
                    )
                    openFolds[newFold.depth] = newFold
                } else if info.depth < currentDepth {
                    for openFold in openFolds.values.filter({ $0.depth > info.depth }) {
                        openFolds.removeValue(forKey: openFold.depth)
                        foldCache.append(
                            LineFoldStorage.RawFold(
                                depth: openFold.depth,
                                range: openFold.range.lowerBound..<info.rangeIndice
                            )
                        )
                    }
                }
                currentDepth = info.depth
            }
        }

        let docEnd = context.documentLength
        for fold in openFolds.values {
            foldCache.append(
                LineFoldStorage.RawFold(
                    depth: fold.depth,
                    range: fold.range.lowerBound..<docEnd
                )
            )
        }
        return foldCache.filter { $0.range.lowerBound < $0.range.upperBound }
    }

    // MARK: - Line ranges

    public static func lineRanges(in document: String) -> [(lineNumber: Int, range: NSRange)] {
        let ns = document as NSString
        var result: [(Int, NSRange)] = []
        var lineNumber = 0
        var location = 0
        let length = ns.length
        while location < length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            ns.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let range = NSRange(location: lineStart, length: lineEnd - lineStart)
            result.append((lineNumber, range))
            lineNumber += 1
            if lineEnd <= location { break }
            location = lineEnd
        }
        if length == 0 {
            result.append((0, NSRange(location: 0, length: 0)))
        }
        return result
    }

    // MARK: - Helpers

    private static func leadingWhitespaceLength(in range: NSRange, text: NSString) -> Int {
        guard range.length > 0 else { return 0 }
        var i = 0
        while i < range.length {
            let ch = text.character(at: range.location + i)
            if ch == 0x0A || ch == 0x0D { return i }
            if ch == 0x20 || ch == 0x09 {
                i += 1
                continue
            }
            return i
        }
        return i
    }

    private static func isWhitespaceOnly(_ range: NSRange, text: NSString) -> Bool {
        guard range.length > 0 else { return true }
        for i in 0..<range.length {
            let ch = text.character(at: range.location + i)
            if ch == 0x0A || ch == 0x0D { continue }
            if ch != 0x20 && ch != 0x09 { return false }
        }
        return true
    }

    private static func contentEndOffset(in lineRange: NSRange, text: NSString) -> Int {
        guard lineRange.length > 0 else { return lineRange.location }
        var end = lineRange.location + lineRange.length
        while end > lineRange.location {
            let ch = text.character(at: end - 1)
            if ch == 0x0A || ch == 0x0D {
                end -= 1
            } else {
                break
            }
        }
        while end > lineRange.location {
            let ch = text.character(at: end - 1)
            if ch == 0x20 || ch == 0x09 {
                end -= 1
            } else {
                break
            }
        }
        return end
    }
}
