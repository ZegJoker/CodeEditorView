import CoreGraphics
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Shared SF Symbol drawing for flipped AppKit / UIKit editor contexts.
///
/// Rasterises the symbol into a non-flipped bitmap, tints it, then draws with an
/// explicit Y-flip so chevrons and diagnostic icons stay upright in `isFlipped` views.
public enum SFSymbolDrawing {
    /// Draw a system symbol centered in `rect`, sized to fit the smaller side.
    public static func draw(
        name: String,
        tint: PlatformColor,
        in rect: CGRect,
        pointSize: CGFloat? = nil,
        weight: PlatformFont.Weight = .regular
    ) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let size = pointSize ?? max(10, min(rect.height, rect.width) * 0.95)
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        let targetSize = NSSize(
            width: max(size, symbol.size.width),
            height: max(size, symbol.size.height)
        )
        let scale: CGFloat = 2
        let pxW = max(1, Int(ceil(targetSize.width * scale)))
        let pxH = max(1, Int(ceil(targetSize.height * scale)))
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
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        let bounds = NSRect(origin: .zero, size: targetSize)
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
            x: rect.midX - targetSize.width / 2,
            y: rect.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        ctx.saveGState()
        ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        ctx.restoreGState()
        #else
        let size = pointSize ?? max(10, min(rect.height, rect.width) * 0.95)
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal) else { return }
        let imgSize = image.size
        let drawRect = CGRect(
            x: rect.midX - imgSize.width / 2,
            y: rect.midY - imgSize.height / 2,
            width: imgSize.width,
            height: imgSize.height
        )
        image.draw(in: drawRect)
        #endif
    }
}
