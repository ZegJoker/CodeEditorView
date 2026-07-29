import CoreGraphics
import CoreText
import Foundation

/// Breaks a logical document line into visual ``LineFragment``s using CoreText.
public struct Typesetter: Sendable {
    public var breakStrategy: LineBreakStrategy

    public init(breakStrategy: LineBreakStrategy = .word) {
        self.breakStrategy = breakStrategy
    }

    public func typeset(
        _ string: NSAttributedString,
        documentRange: NSRange,
        display: TypesetDisplayData,
        attachments: [AnyTextAttachment] = []
    ) -> (fragments: [LineFragment], totalHeight: CGFloat) {
        let attachmentWidth = attachments.reduce(CGFloat(0)) { $0 + $1.width }
        let textMaxWidth = max(1, display.maxWidth - attachmentWidth)

        if string.length == 0 || display.maxWidth <= 0 {
            let height = display.estimatedLineHeight * display.lineHeightMultiplier
            let fragment = LineFragment(
                lineRelativeRange: NSRange(location: 0, length: 0),
                documentRange: NSRange(location: documentRange.location, length: 0),
                width: attachmentWidth,
                height: height,
                ascent: display.estimatedLineHeight * 0.8,
                descent: display.estimatedLineHeight * 0.2,
                leading: 0,
                ctLine: nil,
                attachments: attachments
            )
            return ([fragment], fragment.height)
        }

        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var fragments: [LineFragment] = []
        var start: CFIndex = 0
        let length = string.length
        var totalHeight: CGFloat = 0
        let maxWidth = Double(textMaxWidth)
        var remainingAttachments = attachments

        while start < length {
            var count: CFIndex
            switch breakStrategy {
            case .word:
                count = CTTypesetterSuggestLineBreak(typesetter, start, maxWidth)
                // Word breaks can return the whole remainder for long tokens (e.g. URLs, identifiers).
                // Fall back to cluster breaks so wrap mode still constrains to maxWidth.
                if count > 0 {
                    let probe = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                    let probeWidth = CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil))
                    if probeWidth > textMaxWidth + 0.5, count > 1 {
                        let cluster = CTTypesetterSuggestClusterBreak(typesetter, start, maxWidth)
                        count = max(cluster, 1)
                    }
                }
            case .character:
                count = CTTypesetterSuggestClusterBreak(typesetter, start, maxWidth)
            }

            let take = max(count, 1)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: take))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            // Typographic bounds only — do not use font bounding-box height (often ~1.5× larger).
            let naturalHeight = max(ascent + descent + leading, 1)
            let height = max(naturalHeight, display.estimatedLineHeight) * max(display.lineHeightMultiplier, 0.5)

            let relative = NSRange(location: start, length: take)
            let absolute = NSRange(location: documentRange.location + start, length: take)
            // Place all line attachments on the first fragment for drawing.
            let fragAttachments = start == 0 ? remainingAttachments : []
            if start == 0 { remainingAttachments = [] }

            fragments.append(
                LineFragment(
                    lineRelativeRange: relative,
                    documentRange: absolute,
                    width: textWidth + (start == 0 ? attachmentWidth : 0),
                    height: height,
                    ascent: ascent,
                    descent: descent,
                    leading: leading,
                    ctLine: ctLine,
                    attachments: fragAttachments
                )
            )
            totalHeight += height
            start += take
        }

        return (fragments, totalHeight)
    }
}
