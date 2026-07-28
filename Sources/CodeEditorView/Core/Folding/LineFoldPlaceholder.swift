import CoreGraphics
import CoreText
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Colors for the fold placeholder chip (theme-driven, Xcode-like).
public struct LineFoldPlaceholderStyle: Sendable {
    public var background: CGColor
    public var foreground: CGColor
    public var selectedBackground: CGColor
    public var selectedForeground: CGColor

    public init(
        background: CGColor,
        foreground: CGColor,
        selectedBackground: CGColor,
        selectedForeground: CGColor
    ) {
        self.background = background
        self.foreground = foreground
        self.selectedBackground = selectedBackground
        self.selectedForeground = selectedForeground
    }

    public static func from(theme: EditorTheme) -> LineFoldPlaceholderStyle {
        let invis = theme.invisibles.color.cgColor
        let bg = theme.background.cgColor
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let accent = NSColor.controlAccentColor.cgColor
        #else
        let accent = PlatformColor.systemBlue.cgColor
        #endif
        return LineFoldPlaceholderStyle(
            background: invis.copy(alpha: 0.22) ?? invis,
            foreground: invis.copy(alpha: 0.65) ?? invis,
            selectedBackground: accent,
            selectedForeground: bg
        )
    }
}

/// Inline “···” chip representing a collapsed fold body (Xcode-like).
///
/// The real closing `}` stays in the document on its original line so it remains
/// clickable and editable. Interaction: first click selects (primary color);
/// second click expands. Selecting the fold range + Delete removes the whole body.
public final class LineFoldPlaceholder: TextAttachment {
    public let fold: FoldRange
    public let charWidth: CGFloat
    public var style: LineFoldPlaceholderStyle
    public var isSelected: Bool = false
    public var onExpand: ((FoldRange) -> Void)?
    public var onSelect: ((FoldRange) -> Void)?

    public init(
        fold: FoldRange,
        charWidth: CGFloat,
        style: LineFoldPlaceholderStyle,
        onSelect: ((FoldRange) -> Void)? = nil,
        onExpand: ((FoldRange) -> Void)? = nil
    ) {
        self.fold = fold
        self.charWidth = max(1, charWidth)
        self.style = style
        self.onSelect = onSelect
        self.onExpand = onExpand
    }

    public var width: CGFloat {
        charWidth * 4.5 + charWidth * 0.4
    }

    public func draw(in context: CGContext, rect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }

        let fill = isSelected ? style.selectedBackground : style.background
        let dot = isSelected ? style.selectedForeground : style.foreground
        context.setFillColor(fill)

        let chipW = charWidth * 4.5
        let chipH = max(charWidth * 1.2, min(rect.height * 0.72, charWidth * 1.55))
        let chip = CGRect(
            x: rect.minX + charWidth * 0.15,
            y: rect.midY - chipH / 2,
            width: chipW,
            height: chipH
        )
        let radius = chip.height / 2
        let path = CGPath(roundedRect: chip, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.fillPath()

        let size = max(1.5, charWidth * 0.32)
        let centerY = chip.midY - size / 2
        context.setFillColor(dot)
        let spacing = chipW / 4
        let baseX = chip.minX + spacing - size / 2
        for i in 0..<3 {
            let x = baseX + CGFloat(i) * spacing
            context.fillEllipse(in: CGRect(x: x, y: centerY, width: size, height: size))
        }
    }

    public func attachmentAction() -> TextAttachmentAction {
        if isSelected {
            onExpand?(fold)
            return .discard
        } else {
            onSelect?(fold)
            return .none
        }
    }
}
