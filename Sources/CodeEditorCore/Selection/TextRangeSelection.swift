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
    /// Overflow-safe end (DOC-N05). Invalid arithmetic yields `location`.
    public var end: Int {
        (try? TextOffsetSemantics.utf16EndOffset(location: range.location, length: range.length))
            ?? range.location
    }

    public static func insertionPoint(_ location: Int) -> TextRangeSelection {
        TextRangeSelection(range: NSRange(location: location, length: 0))
    }
}
