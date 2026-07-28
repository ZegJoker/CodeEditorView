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
        guard let ctLine = fragment.ctLine else {
            // No text — attachments start at origin (e.g. empty prefix + fold bubble).
            drawAttachments(fragment.attachments, in: context, origin: origin, height: fragment.height)
            return
        }

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + fragment.height - fragment.descent)
        context.scaleBy(x: 1, y: -1)

        if let textColor {
            context.setFillColor(textColor)
        }
        CTLineDraw(ctLine, context)
        context.restoreGState()

        // Fold placeholders (and other attachments) sit *after* the typeset text — Xcode-style
        // `func f() { ··· }`, not stacked under the glyphs.
        let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        drawAttachments(
            fragment.attachments,
            in: context,
            origin: CGPoint(x: origin.x + textWidth, y: origin.y),
            height: fragment.height
        )
    }

    public static func drawSelection(
        ranges: [NSRange],
        fragments: [LaidOutFragment],
        in context: CGContext,
        color: CGColor
    ) {
        for range in ranges where range.length > 0 {
            drawSelection(range: range, fragments: fragments, in: context, color: color)
        }
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

    @MainActor
    public static func drawCarets(
        offsets: [Int],
        layout: LayoutEngine,
        containerWidth: CGFloat,
        in context: CGContext,
        color: CGColor,
        visible: Bool
    ) {
        guard visible else { return }
        context.setFillColor(color)
        for offset in offsets {
            if let caret = layout.caretRect(atUTF16Offset: offset, containerWidth: containerWidth) {
                context.fill(CGRect(x: caret.minX, y: caret.minY, width: 1.5, height: caret.height))
            }
        }
    }

    private static func drawAttachments(
        _ attachments: [AnyTextAttachment],
        in context: CGContext,
        origin: CGPoint,
        height: CGFloat
    ) {
        var x = origin.x
        for item in attachments {
            let rect = CGRect(x: x, y: origin.y, width: item.width, height: height)
            item.attachment.draw(in: context, rect: rect)
            x += item.width
        }
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
