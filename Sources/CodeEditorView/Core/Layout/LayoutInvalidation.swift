import Foundation
import CodeEditorCore

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

    /// Splits a UTF-16 string into line metrics (including terminators), using estimated height.
    ///
    /// Forwards to ``LineMetrics/splitLines`` so layout and Core share one implementation.
    public static func splitLines(
        in string: String,
        estimatedHeight: CGFloat,
        includeTrailingEmptyLine: Bool = false
    ) -> [LineMetrics] {
        LineMetrics.splitLines(
            in: string,
            estimatedHeight: estimatedHeight,
            includeTrailingEmptyLine: includeTrailingEmptyLine
        )
    }
}
