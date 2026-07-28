import CoreGraphics
import Foundation

/// Platform-agnostic gutter metrics (line-number column).
public struct GutterModel: Equatable {
    public var lineCount: Int
    public var font: PlatformFont
    public var minimumDigitCount: Int
    public var horizontalPadding: CGFloat

    public init(
        lineCount: Int,
        font: PlatformFont,
        minimumDigitCount: Int = 2,
        horizontalPadding: CGFloat = 8
    ) {
        self.lineCount = max(1, lineCount)
        self.font = font
        self.minimumDigitCount = minimumDigitCount
        self.horizontalPadding = horizontalPadding
    }

    public var digitCount: Int {
        max(minimumDigitCount, String(lineCount).count)
    }

    /// Estimated width of the line-number column including padding.
    public var width: CGFloat {
        let sample = String(repeating: "0", count: digitCount)
        let size = (sample as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + horizontalPadding * 2
    }

    public func label(forLineIndex lineIndex: Int) -> String {
        String(lineIndex + 1)
    }
}
