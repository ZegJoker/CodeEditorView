import Foundation

/// Identifies who contributed a language registration (LANG-N01).
///
/// Built-in packs, the host app, and extension packages each use a distinct owner so
/// unregistering one contribution cannot remove another owner's replacement.
public struct ContributionOwner: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Built-in language packs and the umbrella bootstrap.
    public static let builtIn = ContributionOwner(rawValue: "codeeditor.builtin")
    /// Host application explicit contributions.
    public static let host = ContributionOwner(rawValue: "codeeditor.host")

    /// Extension package contribution (`extension:<packageID>`).
    public static func extensionPackage(_ packageID: String) -> ContributionOwner {
        ContributionOwner(rawValue: "extension:\(packageID)")
    }
}
