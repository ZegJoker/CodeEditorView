import Foundation

/// Characters inserted when the user presses Tab.
public enum IndentOption: Equatable, Sendable, Hashable {
    case spaces(count: Int)
    case tab

    public var string: String {
        switch self {
        case .spaces(let count):
            return String(repeating: " ", count: max(0, count))
        case .tab:
            return "\t"
        }
    }

    /// Visual width contribution for a single indent unit (spaces count, or 1 for tab).
    public var visualWidth: Int {
        switch self {
        case .spaces(let count):
            return max(0, count)
        case .tab:
            return 1
        }
    }
}
