import CoreGraphics
import CoreText
import Foundation
import CodeEditorCore

/// A single visual row produced by the typesetter for a logical document line.
public final class LineFragment: LinePayload, Identifiable {
    public let id: UUID
    /// UTF-16 range relative to the logical line start.
    public let lineRelativeRange: NSRange
    /// Absolute document UTF-16 range.
    public let documentRange: NSRange
    public let width: CGFloat
    public let height: CGFloat
    /// Typographic ascent used for baseline placement.
    public let ascent: CGFloat
    public let descent: CGFloat
    /// Typographic leading from Core Text.
    public let leading: CGFloat
    public let ctLine: CTLine?
    /// Attachments drawn on this fragment (document-relative).
    public let attachments: [AnyTextAttachment]

    public init(
        lineRelativeRange: NSRange,
        documentRange: NSRange,
        width: CGFloat,
        height: CGFloat,
        ascent: CGFloat = 0,
        descent: CGFloat,
        leading: CGFloat = 0,
        ctLine: CTLine?,
        attachments: [AnyTextAttachment] = []
    ) {
        self.id = UUID()
        self.lineRelativeRange = lineRelativeRange
        self.documentRange = documentRange
        self.width = width
        self.height = height
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        self.ctLine = ctLine
        self.attachments = attachments
    }

    /// Distance from the top of the fragment box to the text baseline (flipped Y grows down).
    /// Extra line-height padding is split above and below the glyphs (Xcode-like).
    public var baselineFromTop: CGFloat {
        let natural = ascent + descent + leading
        let extra = max(0, height - natural)
        return extra / 2 + ascent
    }
}

/// Display parameters controlling how a logical line is typeset.
public struct TypesetDisplayData: Sendable, Equatable {
    public var maxWidth: CGFloat
    public var lineHeightMultiplier: CGFloat
    public var estimatedLineHeight: CGFloat

    public init(maxWidth: CGFloat, lineHeightMultiplier: CGFloat = 1.0, estimatedLineHeight: CGFloat) {
        self.maxWidth = maxWidth
        self.lineHeightMultiplier = lineHeightMultiplier
        self.estimatedLineHeight = estimatedLineHeight
    }
}
