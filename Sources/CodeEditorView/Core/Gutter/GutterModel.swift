import CoreGraphics
import Foundation

/// Platform-agnostic gutter metrics (line-number column + optional fold ribbon).
public struct GutterModel: Equatable {
    public var lineCount: Int
    public var font: PlatformFont
    public var minimumDigitCount: Int
    public var horizontalPadding: CGFloat
    /// CESE fold ribbon width (~7pt). Zero when folding is off.
    public var foldingRibbonWidth: CGFloat

    public init(
        lineCount: Int,
        font: PlatformFont,
        minimumDigitCount: Int = 2,
        horizontalPadding: CGFloat = 8,
        foldingRibbonWidth: CGFloat = 0
    ) {
        self.lineCount = max(1, lineCount)
        self.font = font
        self.minimumDigitCount = minimumDigitCount
        self.horizontalPadding = horizontalPadding
        self.foldingRibbonWidth = max(0, foldingRibbonWidth)
    }

    public var digitCount: Int {
        max(minimumDigitCount, String(lineCount).count)
    }

    /// Width of the line-number column only (excluding fold ribbon).
    public var numbersWidth: CGFloat {
        let sample = String(repeating: "0", count: digitCount)
        let size = (sample as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + horizontalPadding * 2
    }

    /// Total gutter width including optional fold ribbon.
    public var width: CGFloat {
        numbersWidth + foldingRibbonWidth
    }

    /// X origin of the fold ribbon relative to the gutter leading edge.
    public var foldingRibbonMinX: CGFloat {
        numbersWidth
    }

    public func label(forLineIndex lineIndex: Int) -> String {
        String(lineIndex + 1)
    }
}

/// Shared fold ribbon metrics (CESE `LineFoldRibbonView.width`).
public enum FoldRibbonMetrics: Sendable {
    public static let width: CGFloat = 7
}
