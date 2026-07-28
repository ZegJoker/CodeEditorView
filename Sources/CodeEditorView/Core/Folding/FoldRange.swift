import Foundation

/// A single fold region with a stable identity and collapse state (CESE-aligned).
public struct FoldRange: Equatable, Sendable, Hashable {
    public typealias FoldIdentifier = UInt32

    public let id: FoldIdentifier
    public let depth: Int
    /// UTF-16 half-open range in the document.
    public let range: Range<Int>
    public var isCollapsed: Bool

    public init(id: FoldIdentifier, depth: Int, range: Range<Int>, isCollapsed: Bool) {
        self.id = id
        self.depth = depth
        self.range = range
        self.isCollapsed = isCollapsed
    }

    public var nsRange: NSRange {
        NSRange(location: range.lowerBound, length: max(0, range.upperBound - range.lowerBound))
    }

    /// Whether `other` is nested inside this fold at the same or greater depth band.
    public func isHoveringEqual(_ other: FoldRange) -> Bool {
        depth == other.depth && range.contains(other.range.lowerBound) && range.contains(other.range.upperBound - 1)
            || (depth == other.depth && range == other.range)
    }
}
