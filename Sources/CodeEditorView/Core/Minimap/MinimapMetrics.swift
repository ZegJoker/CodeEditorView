import CoreGraphics
import Foundation

/// Shared constants for minimap sizing (CESE-aligned).
public enum MinimapMetrics: Sendable {
    /// Maximum strip width in points.
    public static let maxWidth: CGFloat = 140
    /// Preferred fraction of host width when unconstrained.
    public static let relativeWidth: CGFloat = 0.17
    /// Floor when minimap is enabled.
    public static let minWidth: CGFloat = 48
    /// Height of each “bubble” row (CESE uses ~2–3pt).
    public static let lineHeight: CGFloat = 3
    /// Horizontal scale: editor character width → minimap x.
    public static let charWidthScale: CGFloat = 1.5
    /// Leading padding inside the minimap content.
    public static let contentLeading: CGFloat = 4
    /// Separator thickness on the leading edge of the strip.
    public static let separatorWidth: CGFloat = 1
}
