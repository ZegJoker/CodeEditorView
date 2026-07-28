import CoreGraphics
import CoreText
import Foundation

/// A single visual row produced by the typesetter for a logical document line.
public final class LineFragment: LinePayload, Identifiable {
    public let id: UUID
    /// UTF-16 range relative to the logical line start.
    public let lineRelativeRange: NSRange
    /// Absolute document UTF-16 range.
    public let documentRange: NSRange
    public let width: CGFloat
    public let height: CGFloat
    public let descent: CGFloat
    public let ctLine: CTLine?

    public init(
        lineRelativeRange: NSRange,
        documentRange: NSRange,
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        ctLine: CTLine?
    ) {
        self.id = UUID()
        self.lineRelativeRange = lineRelativeRange
        self.documentRange = documentRange
        self.width = width
        self.height = height
        self.descent = descent
        self.ctLine = ctLine
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
