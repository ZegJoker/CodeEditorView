import CoreGraphics
import Foundation

/// Visual and interaction configuration for ``CodeEditor`` / ``EditorController``.
public struct EditorConfiguration: Equatable {
    public var font: PlatformFont
    public var textColor: PlatformColor
    public var caretColor: PlatformColor
    public var selectionColor: PlatformColor
    public var lineHeightMultiplier: CGFloat
    public var wrapLines: Bool
    public var isEditable: Bool
    public var isSelectable: Bool
    public var letterSpacing: CGFloat
    public var edgeInsets: HorizontalEdgeInsets
    public var lineBreakStrategy: LineBreakStrategy

    public init(
        font: PlatformFont = PlatformDefaults.monospacedFont,
        textColor: PlatformColor = PlatformDefaults.textColor,
        caretColor: PlatformColor = PlatformDefaults.caretColor,
        selectionColor: PlatformColor = PlatformDefaults.selectionColor,
        lineHeightMultiplier: CGFloat = 1.2,
        wrapLines: Bool = true,
        isEditable: Bool = true,
        isSelectable: Bool = true,
        letterSpacing: CGFloat = 1.0,
        edgeInsets: HorizontalEdgeInsets = HorizontalEdgeInsets(leading: 4, trailing: 4),
        lineBreakStrategy: LineBreakStrategy = .word
    ) {
        self.font = font
        self.textColor = textColor
        self.caretColor = caretColor
        self.selectionColor = selectionColor
        self.lineHeightMultiplier = lineHeightMultiplier
        self.wrapLines = wrapLines
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        self.letterSpacing = letterSpacing
        self.edgeInsets = edgeInsets
        self.lineBreakStrategy = lineBreakStrategy
    }

    public var typingAttributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        if letterSpacing != 1.0 {
            let width = (" " as NSString).size(withAttributes: [.font: font]).width
            attrs[.kern] = width * (letterSpacing - 1.0)
        }
        return attrs
    }
}

// PlatformFont/Color are not formally Sendable; configuration is main-actor consumed.
extension EditorConfiguration: @unchecked Sendable {}
