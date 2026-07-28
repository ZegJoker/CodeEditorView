import CoreGraphics
import Foundation

/// One painted row in the minimap content view.
public struct MinimapLinePaint: Equatable, Sendable {
    public var y: CGFloat
    public var height: CGFloat
    public var bubbles: [MinimapBubbleRun]
    /// Document line index (for hit testing / debug).
    public var lineIndex: Int

    public init(y: CGFloat, height: CGFloat, bubbles: [MinimapBubbleRun], lineIndex: Int) {
        self.y = y
        self.height = height
        self.bubbles = bubbles
        self.lineIndex = lineIndex
    }
}

/// Snapshot of minimap content for a vertical slice.
public struct MinimapSnapshot: Equatable, Sendable {
    public var contentHeight: CGFloat
    public var lines: [MinimapLinePaint]
    public var selectionRects: [CGRect]

    public init(contentHeight: CGFloat, lines: [MinimapLinePaint], selectionRects: [CGRect] = []) {
        self.contentHeight = contentHeight
        self.lines = lines
        self.selectionRects = selectionRects
    }

    public static let empty = MinimapSnapshot(contentHeight: 0, lines: [], selectionRects: [])
}
