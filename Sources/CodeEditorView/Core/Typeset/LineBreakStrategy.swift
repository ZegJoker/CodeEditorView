import Foundation

/// Strategy used when wrapping a logical line into visual fragments.
public enum LineBreakStrategy: Sendable, Hashable {
    /// Prefer breaks at word boundaries.
    case word
    /// Break at the nearest character when width is exceeded.
    case character
}
