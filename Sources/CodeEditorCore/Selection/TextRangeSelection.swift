import CoreGraphics
import Foundation

/// A single selection or insertion point.
public struct TextRangeSelection: Equatable, Sendable, Hashable {
    public var range: NSRange
    /// Preferred horizontal caret position for vertical movement.
    public var preferredX: CGFloat?

    public init(range: NSRange, preferredX: CGFloat? = nil) {
        self.range = range
        self.preferredX = preferredX
    }

    public var isInsertionPoint: Bool { range.length == 0 }
    public var location: Int { range.location }
    public var end: Int { range.location + range.length }

    public static func insertionPoint(_ location: Int) -> TextRangeSelection {
        TextRangeSelection(range: NSRange(location: location, length: 0))
    }
}
