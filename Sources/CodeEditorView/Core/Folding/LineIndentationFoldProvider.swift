import Foundation

/// Fold provider that uses line indentation (CESE `LineIndentationFoldProvider`).
///
/// Nesting uses **relative** depth so 2-space (Bash) and 4-space (Swift) both work even
/// when `indentOption` does not match the file’s indent width.
///
/// - Depth decreases → end fold at end of leading whitespace.
/// - Next line more indented → start fold at end of this line’s content (after `{` etc.).
/// - Blank lines contribute nothing.
@MainActor
public final class LineIndentationFoldProvider: LineFoldProvider {
    public init() {}

    public func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        context: LineFoldProviderContext
    ) -> [LineFoldProviderLineInfo] {
        let text = context.nsDocument
        guard lineRange.length > 0, lineRange.location + lineRange.length <= text.length else {
            return []
        }

        let leadingIndent = leadingWhitespaceLength(in: lineRange, text: text, stopAtNewline: true)
        // Blank / whitespace-only line.
        if leadingIndent == lineRange.length {
            return []
        }

        var foldIndicators: [LineFoldProviderLineInfo] = []
        // Absolute indent level in characters (spaces/tabs each count as 1).
        // Compare with previous *absolute* depth via previousDepth which we store as indent chars.
        let leadingDepth = leadingIndent

        if leadingDepth < previousDepth {
            foldIndicators.append(
                .endFold(
                    rangeEnd: lineRange.location + leadingIndent,
                    newDepth: leadingDepth
                )
            )
        }

        // Effective depth after processing ends on this line.
        let depthAfterEnds = leadingDepth < previousDepth ? leadingDepth : previousDepth

        // Next line's leading indent (spaces/tabs only, not newlines).
        let afterLine = lineRange.location + lineRange.length
        guard afterLine < text.length else { return foldIndicators }
        let rest = NSRange(location: afterLine, length: text.length - afterLine)
        let nextIndent = leadingWhitespaceLength(in: rest, text: text, stopAtNewline: false)

        // Start a fold when the next non-empty line is more indented.
        // Always increase nesting depth by at least 1 so unit mismatches (2-space file,
        // 4-space config) still produce real fold ranges.
        if nextIndent > leadingIndent {
            let newDepth = max(depthAfterEnds + 1, nextIndent)
            // Fold starts at the end of non-ws content (typically just after `{`).
            let start = contentEndOffset(in: lineRange, text: text)
            foldIndicators.append(
                .startFold(
                    rangeStart: start,
                    newDepth: newDepth
                )
            )
        }

        return foldIndicators
    }

    // MARK: - Helpers

    private func leadingWhitespaceLength(in range: NSRange, text: NSString, stopAtNewline: Bool) -> Int {
        guard range.length > 0 else { return 0 }
        var i = 0
        while i < range.length {
            let ch = text.character(at: range.location + i)
            if ch == 0x0A || ch == 0x0D {
                return stopAtNewline ? range.length : i
            }
            if ch == 0x20 || ch == 0x09 {
                i += 1
                continue
            }
            return i
        }
        return i
    }

    /// UTF-16 offset of the end of non-whitespace content on the line (before trailing ws / terminator).
    private func contentEndOffset(in lineRange: NSRange, text: NSString) -> Int {
        guard lineRange.length > 0 else { return lineRange.location }
        var end = lineRange.location + lineRange.length
        // Strip terminators.
        while end > lineRange.location {
            let ch = text.character(at: end - 1)
            if ch == 0x0A || ch == 0x0D {
                end -= 1
            } else {
                break
            }
        }
        // Strip trailing spaces/tabs.
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
