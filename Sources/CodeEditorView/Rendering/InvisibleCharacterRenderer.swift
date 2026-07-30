import CoreGraphics
import CoreText
import Foundation
import CodeEditorCore

public enum InvisibleCharacterRenderer {
    public static func draw(
        delegate: InvisibleCharactersDelegate,
        document: DocumentStore,
        fragments: [LaidOutFragment],
        in context: CGContext,
        font: CTFont
    ) {
        let triggers = delegate.triggerCharacters
        guard !triggers.isEmpty else { return }

        for item in fragments {
            let range = item.fragment.documentRange
            guard range.length > 0,
                  let text = document.substring(from: range) else { continue }
            let ns = text as NSString
            var utf16Offset = 0
            while utf16Offset < ns.length {
                let unit = ns.character(at: utf16Offset)
                let charRange = NSRange(location: range.location + utf16Offset, length: 1)
                defer { utf16Offset += 1 }
                guard triggers.contains(unit),
                      let style = delegate.invisibleStyle(for: unit, at: charRange, lineRange: range)
                else { continue }

                let local = utf16Offset
                let x: CGFloat
                if let ctLine = item.fragment.ctLine {
                    x = item.frame.minX + CGFloat(CTLineGetOffsetForStringIndex(ctLine, local, nil))
                } else {
                    x = item.frame.minX
                }
                let origin = CGPoint(x: x, y: item.frame.minY)

                switch style {
                case .replace(let replacement, let color):
                    drawString(replacement, at: origin, height: item.frame.height, font: font, color: color, in: context)
                case .emphasize(let color):
                    context.saveGState()
                    context.setFillColor(color)
                    context.fill(CGRect(x: origin.x, y: origin.y, width: 4, height: item.frame.height))
                    context.restoreGState()
                }
            }
        }
    }

    private static func drawString(
        _ string: String,
        at origin: CGPoint,
        height: CGFloat,
        font: CTFont,
        color: CGColor,
        in context: CGContext
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        let attr = NSAttributedString(string: string, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + height * 0.75)
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
