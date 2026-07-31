import Foundation

/// Typed Tree-sitter query categories (Zed-style suite).
public enum QueryKind: String, Sendable, Hashable, Codable, CaseIterable {
    case highlights
    case injections
    case folds
    case indents
    case locals
    case tags
    case outline
    case textobjects
    case structure
    case brackets

    /// Basename without extension (e.g. `highlights` → `highlights.scm`).
    public var fileBasename: String { rawValue }

    public var fileName: String { "\(rawValue).scm" }

    /// Whether this kind is merged into highlight configurations.
    public var isHighlightFamily: Bool {
        self == .highlights || rawValue.hasPrefix("highlights")
    }
}
