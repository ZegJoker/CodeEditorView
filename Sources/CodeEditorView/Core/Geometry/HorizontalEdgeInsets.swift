import CoreGraphics

/// Horizontal padding applied to content layout and selection chrome.
public struct HorizontalEdgeInsets: Equatable, Sendable, Hashable {
    public var leading: CGFloat
    public var trailing: CGFloat

    public init(leading: CGFloat = 0, trailing: CGFloat = 0) {
        self.leading = leading
        self.trailing = trailing
    }

    public static let zero = HorizontalEdgeInsets()

    public var horizontal: CGFloat { leading + trailing }

    public static func + (lhs: HorizontalEdgeInsets, rhs: HorizontalEdgeInsets) -> HorizontalEdgeInsets {
        HorizontalEdgeInsets(leading: lhs.leading + rhs.leading, trailing: lhs.trailing + rhs.trailing)
    }

    public static func - (lhs: HorizontalEdgeInsets, rhs: HorizontalEdgeInsets) -> HorizontalEdgeInsets {
        HorizontalEdgeInsets(leading: lhs.leading - rhs.leading, trailing: lhs.trailing - rhs.trailing)
    }
}
