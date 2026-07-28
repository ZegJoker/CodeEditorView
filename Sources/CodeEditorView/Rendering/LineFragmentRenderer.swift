import CoreGraphics
import CoreText
import Foundation

/// Shared CoreGraphics drawing for typeset fragments.
public enum LineFragmentRenderer {
    public static func draw(
        _ fragment: LineFragment,
        in context: CGContext,
        origin: CGPoint,
        textColor: CGColor? = nil
    ) {
        guard let ctLine = fragment.ctLine else { return }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + fragment.height - fragment.descent)
        context.scaleBy(x: 1, y: -1)

        if let textColor {
            context.setFillColor(textColor)
        }
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    public static func drawSelection(
        range: NSRange,
        fragments: [LaidOutFragment],
        in context: CGContext,
        color: CGColor
    ) {
        guard range.length > 0 else { return }
        context.saveGState()
        context.setFillColor(color)

        for item in fragments {
            let fragRange = item.fragment.documentRange
            guard let intersection = fragRange.intersection(range), intersection.length > 0 else { continue }
            let localStart = intersection.location - fragRange.location
            let localEnd = localStart + intersection.length

            let x0: CGFloat
            let x1: CGFloat
            if let ctLine = item.fragment.ctLine {
                x0 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, localStart, nil))
                x1 = CGFloat(CTLineGetOffsetForStringIndex(ctLine, localEnd, nil))
            } else {
                x0 = 0
                x1 = item.frame.width
            }
            let rect = CGRect(
                x: item.frame.minX + min(x0, x1),
                y: item.frame.minY,
                width: max(1, abs(x1 - x0)),
                height: item.frame.height
            )
            context.fill(rect)
        }
        context.restoreGState()
    }
}

private extension NSRange {
    func intersection(_ other: NSRange) -> NSRange? {
        let start = Swift.max(location, other.location)
        let end = Swift.min(location + length, other.location + other.length)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
