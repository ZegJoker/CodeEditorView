import Foundation

public enum NavigationDirection: Sendable, Hashable {
    case left
    case right
    case up
    case down
}

public enum NavigationGranularity: Sendable, Hashable {
    case character
    case word
    case line
    case paragraph
    case document
}
