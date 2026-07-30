import Foundation

/// Visual treatment for matched bracket pairs under the caret.
public enum BracketPairEmphasis: Equatable, Sendable, Hashable {
    /// Briefly flash both brackets using the emphasis system.
    case flash
    /// Persistent outline around both brackets.
    case bordered
    /// Persistent underline under both brackets.
    case underline
}
