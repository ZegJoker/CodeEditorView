import Foundation

/// High-level editor notifications delivered through structured concurrency streams.
public enum EditorEvent: Sendable, Equatable {
    case willChangeText
    case textDidChange
    case selectionDidChange
}
