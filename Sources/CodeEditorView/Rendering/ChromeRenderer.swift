import CodeEditorCore
import CoreGraphics
import Foundation

/// Draws editor chrome that is not part of text fragments (line highlight, column guide).
package enum ChromeRenderer {
    /// Fills full-width backgrounds for the given line indices.
    public static func drawLineHighlights(
        lineIndices: Set<Int>,
        lineIndex: LineIndex<some LinePayload>,
        contentWidth: CGFloat,
        gutterWidth: CGFloat,
        color: CGColor,
        in context: CGContext
    ) {
        guard !lineIndices.isEmpty else { return }
        context.saveGState()
        context.setFillColor(color)
        for index in lineIndices {
            guard let line = lineIndex.line(atIndex: index) else { continue }
            let rect = CGRect(
                x: gutterWidth,
                y: line.yOffset,
                width: max(0, contentWidth - gutterWidth),
                height: line.metrics.height
            )
            context.fill(rect)
        }
        context.restoreGState()
    }

    /// Vertical reformatting guide at a character column (1-based ruler: column 40 sits after 40 characters).
    public static func drawReformattingGuide(
        column: Int,
        characterWidth: CGFloat,
        textLeadingInset: CGFloat,
        visibleRect: CGRect,
        color: CGColor,
        in context: CGContext
    ) {
        guard column > 0, characterWidth > 0 else { return }
        // Place the ruler at the trailing edge of character `column` (columns are 1-based).
        let x = textLeadingInset + CGFloat(column) * characterWidth
        // Skip if guide is far outside the dirty/visible strip (still draw slight overflow).
        guard x >= visibleRect.minX - 2, x <= visibleRect.maxX + 2 else { return }
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 2])
        // Snap to pixel center for a crisp 1pt dashed line.
        let snappedX = (x * 2).rounded() / 2
        context.move(to: CGPoint(x: snappedX, y: visibleRect.minY))
        context.addLine(to: CGPoint(x: snappedX, y: visibleRect.maxY))
        context.strokePath()
        context.restoreGState()
    }
}
