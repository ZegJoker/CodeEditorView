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
        display: TypesetDisplayData
    ) -> (fragments: [LineFragment], totalHeight: CGFloat) {
        if string.length == 0 || display.maxWidth <= 0 {
            let fragment = LineFragment(
                lineRelativeRange: NSRange(location: 0, length: 0),
                documentRange: NSRange(location: documentRange.location, length: 0),
                width: 0,
                height: display.estimatedLineHeight * display.lineHeightMultiplier,
                descent: 0,
                ctLine: nil
            )
            return ([fragment], fragment.height)
        }

        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var fragments: [LineFragment] = []
        var start: CFIndex = 0
        let length = string.length
        var totalHeight: CGFloat = 0
        let maxWidth = Double(display.maxWidth)

        while start < length {
            let count: CFIndex
            switch breakStrategy {
            case .word:
                count = CTTypesetterSuggestLineBreak(typesetter, start, maxWidth)
            case .character:
                count = CTTypesetterSuggestClusterBreak(typesetter, start, maxWidth)
            }

            let take = max(count, 1)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: take))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            let naturalHeight = ascent + descent + leading
            let height = max(naturalHeight, display.estimatedLineHeight) * display.lineHeightMultiplier

            let relative = NSRange(location: start, length: take)
            let absolute = NSRange(location: documentRange.location + start, length: take)
            fragments.append(
                LineFragment(
                    lineRelativeRange: relative,
                    documentRange: absolute,
                    width: width,
                    height: height,
                    descent: descent,
                    ctLine: ctLine
                )
            )
            totalHeight += height
            start += take
        }

        return (fragments, totalHeight)
    }
}
