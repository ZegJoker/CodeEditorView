import CoreGraphics
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Draws trailing inline diagnostic chips (mchakravarty `MessageInlineView` style).
///
/// Layout: **right side of each annotated line**, same height as the line —
/// `[count?][SF Symbol icons] | summary…` with severity-tinted fill and rounded left corners.
///
/// Uses platform string/image drawing (not raw `CTLineDraw`) so flipped AppKit views stay upright.
public enum AnnotationRenderer {
    /// Distance of the expanded popup from the trailing edge (mchakravarty `popupRightSideOffset`).
    public static let popupRightSideOffset: CGFloat = 20

    /// Draw trailing chips for annotated lines in the viewport.
    ///
    /// - Parameter excludingLine: When a line is expanded to the full popup, its chip is hidden
    ///   (mchakravarty inline ↔ popup opacity toggle).
    public static func draw(
        annotationsByLine: [Int: [LineAnnotation]],
        lineIndex: LineIndex<TextLine>,
        textLeading: CGFloat,
        contentWidth: CGFloat,
        visibleRect: CGRect,
        excludingLine: Int? = nil,
        in context: CGContext
    ) {
        guard !annotationsByLine.isEmpty else { return }
        let chipMaxW = max(
            AnnotationMetrics.minimumChipWidth,
            contentWidth * AnnotationMetrics.maxWidthFraction
        )

        for (lineIdx, anns) in annotationsByLine {
            if let excludingLine, lineIdx == excludingLine { continue }
            guard !anns.isEmpty,
                  let line = lineIndex.line(atIndex: lineIdx),
                  line.metrics.height >= 0.5
            else { continue }

            let lineRect = CGRect(
                x: textLeading,
                y: line.yOffset,
                width: max(1, contentWidth - textLeading - AnnotationMetrics.trailingInset),
                height: line.metrics.height
            )
            guard lineRect.intersects(visibleRect) else { continue }

            let chip = makeChip(annotations: anns, lineRect: lineRect, maxWidth: chipMaxW)
            drawChip(chip, in: context)
        }
    }

    /// Hit-test a point against trailing chips; returns line index if hit.
    ///
    /// - Parameter excludingLine: Skip this line (e.g. currently expanded popup, chip hidden).
    public static func hitTestLine(
        at point: CGPoint,
        annotationsByLine: [Int: [LineAnnotation]],
        lineIndex: LineIndex<TextLine>,
        textLeading: CGFloat,
        contentWidth: CGFloat,
        excludingLine: Int? = nil
    ) -> Int? {
        let chipMaxW = max(
            AnnotationMetrics.minimumChipWidth,
            contentWidth * AnnotationMetrics.maxWidthFraction
        )
        for (lineIdx, anns) in annotationsByLine {
            if let excludingLine, lineIdx == excludingLine { continue }
            guard !anns.isEmpty,
                  let line = lineIndex.line(atIndex: lineIdx),
                  line.metrics.height >= 0.5
            else { continue }
            let lineRect = CGRect(
                x: textLeading,
                y: line.yOffset,
                width: max(1, contentWidth - textLeading - AnnotationMetrics.trailingInset),
                height: line.metrics.height
            )
            let chip = makeChip(annotations: anns, lineRect: lineRect, maxWidth: chipMaxW)
            if chip.frame.contains(point) {
                return lineIdx
            }
        }
        return nil
    }

    // MARK: - Chip geometry

    private struct ChipLayout {
        var frame: CGRect
        var iconStripWidth: CGFloat
        var summary: String
        var color: PlatformColor
        var categories: [DiagnosticSeverity]
        var count: Int
    }

    private static func makeChip(
        annotations: [LineAnnotation],
        lineRect: CGRect,
        maxWidth: CGFloat
    ) -> ChipLayout {
        let sorted = annotations.sorted {
            AnnotationMetrics.priority($0.severity) < AnnotationMetrics.priority($1.severity)
        }
        let top = sorted[0]
        var seen = Set<DiagnosticSeverity>()
        var categories: [DiagnosticSeverity] = []
        for a in sorted where seen.insert(a.severity).inserted {
            categories.append(a.severity)
        }

        let count = annotations.count
        let countW: CGFloat = count > 1 ? 16 : 0
        let iconsW = CGFloat(categories.count) * (AnnotationMetrics.iconSize + 4) + 8
        let stripW = countW + iconsW
        let summary = top.message
        let approxChar: CGFloat = 7
        let summaryNeed = min(CGFloat(summary.count) * approxChar + 16, maxWidth - stripW)
        let totalW = min(maxWidth, max(AnnotationMetrics.minimumChipWidth, stripW + max(40, summaryNeed)))
        let height = max(14, lineRect.height - 2)
        let frame = CGRect(
            x: lineRect.maxX - totalW,
            y: lineRect.minY + (lineRect.height - height) / 2,
            width: totalW,
            height: height
        )
        return ChipLayout(
            frame: frame,
            iconStripWidth: stripW,
            summary: summary,
            color: top.severity.color,
            categories: categories,
            count: count
        )
    }

    private static func drawChip(_ chip: ChipLayout, in context: CGContext) {
        let rect = chip.frame
        let r = AnnotationMetrics.cornerRadius
        let color = chip.color

        context.saveGState()
        defer { context.restoreGState() }

        // Rounded-left pill.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + r),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(color.withAlphaComponent(0.5).cgColor)
        context.fillPath()

        // Icon strip
        context.setFillColor(color.withAlphaComponent(0.2).cgColor)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: chip.iconStripWidth, height: rect.height))

        // Divider (CG — orientation-independent)
        context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        let divX = rect.minX + chip.iconStripWidth
        context.move(to: CGPoint(x: divX, y: rect.minY + 2))
        context.addLine(to: CGPoint(x: divX, y: rect.maxY - 2))
        context.strokePath()

        // Text + SF Symbols via platform APIs (correct in flipped AppKit views).
        withPlatformGraphics(context: context) {
            let textColor = PlatformColor.black.withAlphaComponent(0.9)
            var x = rect.minX + AnnotationMetrics.horizontalPadding

            if chip.count > 1 {
                let font = monospacedFont(size: 10, bold: true)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                let s = "\(chip.count)" as NSString
                let sz = s.size(withAttributes: attrs)
                s.draw(
                    at: CGPoint(x: x, y: rect.midY - sz.height / 2),
                    withAttributes: attrs
                )
                x += sz.width + 4
            }

            for cat in chip.categories {
                let iconRect = CGRect(
                    x: x,
                    y: rect.midY - AnnotationMetrics.iconSize / 2,
                    width: AnnotationMetrics.iconSize,
                    height: AnnotationMetrics.iconSize
                )
                drawSFSymbol(name: cat.systemImage, tint: cat.color, in: iconRect)
                x += AnnotationMetrics.iconSize + 4
            }

            let summaryX = divX + 6
            let summaryW = max(1, rect.maxX - summaryX - AnnotationMetrics.horizontalPadding)
            let font = monospacedFont(size: 11, bold: false)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let s = chip.summary as NSString
            let sz = s.size(withAttributes: attrs)
            let drawRect = CGRect(
                x: summaryX,
                y: rect.midY - sz.height / 2,
                width: summaryW,
                height: sz.height
            )
            s.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrs
            )
        }
    }

    // MARK: - Platform drawing

    private static func monospacedFont(size: CGFloat, bold: Bool) -> PlatformFont {
        .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private static func withPlatformGraphics(context: CGContext, _ body: () -> Void) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        #else
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
        #endif
    }

    private static func drawSFSymbol(name: String, tint: PlatformColor, in rect: CGRect) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Rasterise the symbol into a bitmap (bottom-left origin), then draw the CGImage
        // with an explicit Y-flip so it stays upright in our flipped AppKit editor view.
        // NSImage.draw(respectFlipped:) was producing upside-down warning triangles.
        let pointSize = max(10, min(rect.height, rect.width) * 0.95)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let size = NSSize(
            width: max(pointSize, symbol.size.width),
            height: max(pointSize, symbol.size.height)
        )
        let scale: CGFloat = 2
        let pxW = max(1, Int(ceil(size.width * scale)))
        let pxH = max(1, Int(ceil(size.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: size)
        // Draw as template, then tint via sourceAtop.
        let template = symbol.copy() as? NSImage ?? symbol
        template.isTemplate = true
        template.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        tint.set()
        bounds.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage,
              let ctx = NSGraphicsContext.current?.cgContext
        else { return }

        let drawRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Flip Y while drawing so the bitmap’s upright symbol stays upright in a flipped view.
        ctx.saveGState()
        ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        ctx.restoreGState()
        #else
        let config = UIImage.SymbolConfiguration(pointSize: max(10, min(rect.height, rect.width) * 0.95), weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
        let size = image.size
        let drawRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: drawRect)
        #endif
    }
}
