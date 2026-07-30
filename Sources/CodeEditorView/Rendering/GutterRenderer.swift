import CoreGraphics
import CoreText
import Foundation
import CodeEditorCore

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Draws the line-number gutter (+ optional fold ribbon) into a Core Graphics context.
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
        folds: [FoldRange] = [],
        in context: CGContext
    ) {
        let width = model.width
        guard width > 0 else { return }

        context.saveGState()
        context.setFillColor(backgroundColor)
        context.fill(CGRect(x: 0, y: visibleRect.minY, width: width, height: visibleRect.height))

        // Divider at trailing edge of gutter
        context.setStrokeColor(textColor.copy(alpha: 0.15) ?? textColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: width - 0.5, y: visibleRect.minY))
        context.addLine(to: CGPoint(x: width - 0.5, y: visibleRect.maxY))
        context.strokePath()

        guard lineIndex.count > 0 else {
            context.restoreGState()
            return
        }

        let numbersWidth = model.numbersWidth

        lineIndex.enumerateLines(inYRange: visibleRect.minY, maxY: visibleRect.maxY) { line in
            if line.metrics.height < 0.5 { return }
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
            // Numbers sit in the numbers column (left of ribbon).
            let x = numbersWidth - model.horizontalPadding - size.width
            let y = line.yOffset + (line.metrics.height - size.height) / 2
            label.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }

        if model.foldingRibbonWidth > 0.5 {
            drawFoldRibbon(
                model: model,
                lineIndex: lineIndex,
                visibleRect: visibleRect,
                folds: folds,
                textColor: textColor,
                in: context
            )
        }

        context.restoreGState()
    }

    /// Disclosure markers on fold-start lines using SF Symbol chevrons.
    private static func drawFoldRibbon(
        model: GutterModel,
        lineIndex: LineIndex<some LinePayload>,
        visibleRect: CGRect,
        folds: [FoldRange],
        textColor: CGColor,
        in context: CGContext
    ) {
        let ribbonX = model.foldingRibbonMinX
        let ribbonW = model.foldingRibbonWidth
        guard ribbonW > 0 else { return }

        // Faint vertical guide at the leading edge of the ribbon.
        context.setStrokeColor(textColor.copy(alpha: 0.08) ?? textColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: ribbonX + 0.5, y: visibleRect.minY))
        context.addLine(to: CGPoint(x: ribbonX + 0.5, y: visibleRect.maxY))
        context.strokePath()

        let openTint = platformColor(from: textColor.copy(alpha: 0.55) ?? textColor)
        let collapsedTint = platformColor(from: textColor.copy(alpha: 0.9) ?? textColor)
        let iconSize = FoldRibbonMetrics.iconPointSize

        // Disclosure on the **header** line (line before the first body line where the
        // fold range starts). The `···` bubble lives on the first body line when collapsed.
        var headerMarkers: [Int: FoldRange] = [:]
        for fold in folds {
            guard let bodyStart = lineIndex.line(atUTF16Offset: fold.range.lowerBound) else { continue }
            // Walk up to previous visible non-empty header line.
            var headerIdx = bodyStart.index - 1
            while headerIdx >= 0 {
                guard let header = lineIndex.line(atIndex: headerIdx) else { break }
                if header.metrics.height >= 0.5 {
                    if let existing = headerMarkers[headerIdx] {
                        if fold.depth < existing.depth {
                            headerMarkers[headerIdx] = fold
                        }
                    } else {
                        headerMarkers[headerIdx] = fold
                    }
                    break
                }
                headerIdx -= 1
            }
        }

        // NSString line labels already rely on the view’s NSGraphicsContext; keep the same
        // context for SF Symbols so upright drawing works in flipped AppKit editors.
        for (lineIdx, fold) in headerMarkers {
            guard let headerLine = lineIndex.line(atIndex: lineIdx) else { continue }
            guard headerLine.metrics.height >= 0.5 else { continue }
            let cy = headerLine.yOffset + headerLine.metrics.height / 2
            let cx = ribbonX + ribbonW / 2
            guard cy >= visibleRect.minY - 4, cy <= visibleRect.maxY + 4 else { continue }

            let iconRect = CGRect(
                x: cx - iconSize / 2,
                y: cy - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            if fold.isCollapsed {
                SFSymbolDrawing.draw(
                    name: FoldRibbonMetrics.collapsedSymbolName,
                    tint: collapsedTint,
                    in: iconRect,
                    pointSize: iconSize,
                    weight: .ultraLight
                )
            } else {
                SFSymbolDrawing.draw(
                    name: FoldRibbonMetrics.expandedSymbolName,
                    tint: openTint,
                    in: iconRect,
                    pointSize: iconSize,
                    weight: .ultraLight
                )
            }
        }
    }

    private static func platformColor(from cgColor: CGColor) -> PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSColor(cgColor: cgColor) ?? PlatformDefaults.textColor
        #else
        UIColor(cgColor: cgColor)
        #endif
    }
}
