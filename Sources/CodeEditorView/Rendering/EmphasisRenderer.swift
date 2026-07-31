import CoreGraphics
import CoreText
import Foundation

package enum EmphasisRenderer {
    public static func draw(
        _ emphases: [Emphasis],
        fragments: [LaidOutFragment],
        in context: CGContext,
        standardFill: CGColor,
        outlineStroke: CGColor
    ) {
        for emphasis in emphases {
            let alpha: CGFloat = emphasis.inactive ? 0.35 : 1.0
            context.saveGState()
            context.setAlpha(alpha)

            switch emphasis.style {
            case .standard, .fill:
                fill(
                    range: emphasis.range,
                    fragments: fragments,
                    in: context,
                    color: emphasis.color ?? standardFill
                )
            case .outline:
                outline(
                    range: emphasis.range,
                    fragments: fragments,
                    in: context,
                    color: emphasis.color ?? outlineStroke
                )
            case .underline:
                underline(
                    range: emphasis.range,
                    fragments: fragments,
                    in: context,
                    color: emphasis.color ?? outlineStroke
                )
            }
            context.restoreGState()
        }
    }

    private static func fill(range: NSRange, fragments: [LaidOutFragment], in context: CGContext, color: CGColor) {
        context.setFillColor(color)
        for rect in rects(for: range, fragments: fragments) {
            context.fill(rect)
        }
    }

    private static func outline(range: NSRange, fragments: [LaidOutFragment], in context: CGContext, color: CGColor) {
        context.setStrokeColor(color)
        context.setLineWidth(1)
        for rect in rects(for: range, fragments: fragments) {
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private static func underline(range: NSRange, fragments: [LaidOutFragment], in context: CGContext, color: CGColor) {
        context.setStrokeColor(color)
        context.setLineWidth(2)
        context.setLineCap(.round)
        for rect in rects(for: range, fragments: fragments) {
            let y = rect.maxY - 1.5
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
        }
    }

    private static func rects(for range: NSRange, fragments: [LaidOutFragment]) -> [CGRect] {
        var result: [CGRect] = []
        for item in fragments {
            let frag = item.fragment.documentRange
            let start = max(range.location, frag.location)
            let end = min(range.location + range.length, frag.location + frag.length)
            guard end > start else { continue }
            let localStart = start - frag.location
            let localEnd = end - frag.location
            let x0: CGFloat
            let x1: CGFloat
            if let ctLine = item.fragment.ctLine {
                x0 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, localStart, nil))
                x1 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, localEnd, nil))
            } else {
                x0 = 0
                x1 = item.frame.width
            }
            result.append(
                CGRect(
                    x: item.frame.minX + min(x0, x1),
                    y: item.frame.minY,
                    width: max(1, abs(x1 - x0)),
                    height: item.frame.height
                )
            )
        }
        return result
    }
}
