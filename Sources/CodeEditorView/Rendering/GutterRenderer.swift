import CoreGraphics
import CoreText
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Draws the line-number gutter into a Core Graphics context.
public enum GutterRenderer {
    public static func draw(
        model: GutterModel,
        lineIndex: LineIndex<some LinePayload>,
        visibleRect: CGRect,
        selectedLineIndices: Set<Int>,
        textColor: CGColor,
        selectedTextColor: CGColor,
        backgroundColor: CGColor,
        selectedLineColor: CGColor,
        in context: CGContext
    ) {
        let width = model.width
        guard width > 0 else { return }

        context.saveGState()
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: visibleRect.minY, width: width, height: visibleRect.height))

        // Divider
        context.setStrokeColor(textColor.copy(alpha: 0.15) ?? textColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: width - 0.5, y: visibleRect.minY))
        context.addLine(to: CGPoint(x: width - 0.5, y: visibleRect.maxY))
        context.strokePath()

        guard lineIndex.count > 0 else {
            context.restoreGState()
            return
        }

        lineIndex.enumerateLines(inYRange: visibleRect.minY, maxY: visibleRect.maxY) { line in
            let isSelected = selectedLineIndices.contains(line.index)
            if isSelected {
                context.setFillColor(selectedLineColor)
                context.fill(CGRect(x: 0, y: line.yOffset, width: width, height: line.metrics.height))
            }

            let label = model.label(forLineIndex: line.index) as NSString
            let color = isSelected ? selectedTextColor : textColor
            let attributes: [NSAttributedString.Key: Any] = [
                .font: model.font,
                .foregroundColor: platformColor(from: color),
            ]
            let size = label.size(withAttributes: attributes)
            let x = width - model.horizontalPadding - size.width
            let y = line.yOffset + (line.metrics.height - size.height) / 2
            label.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }

        context.restoreGState()
    }

    private static func platformColor(from cgColor: CGColor) -> PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSColor(cgColor: cgColor) ?? PlatformDefaults.textColor
        #else
        UIColor(cgColor: cgColor)
        #endif
    }
}
