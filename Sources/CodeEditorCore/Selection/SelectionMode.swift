import Foundation

/// How pointer-driven selection grows.
public enum SelectionMode: Sendable, Hashable {
    case character
    case column
}
