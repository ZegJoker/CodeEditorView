import Foundation

/// Stable extension identifier (e.g. `com.example.hello`).
public struct ExtensionID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

/// Semantic version for manifests and host API negotiation.
public struct SemanticVersion: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    public static let zero = SemanticVersion(major: 0, minor: 0, patch: 0)

    /// Phase 9 host API version.
    public static let phase9API = SemanticVersion(major: 1, minor: 0, patch: 0)

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func parse(_ string: String) -> SemanticVersion? {
        let parts = string.split(separator: ".").map(String.init)
        guard let major = parts.first.flatMap(Int.init) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }
}

/// Inclusive minimum, optional exclusive maximum.
public struct VersionRange: Hashable, Codable, Sendable {
    public var min: SemanticVersion
    public var maxExclusive: SemanticVersion?

    public init(min: SemanticVersion, maxExclusive: SemanticVersion? = nil) {
        self.min = min
        self.maxExclusive = maxExclusive
    }

    public static func from(_ min: SemanticVersion) -> VersionRange {
        VersionRange(min: min, maxExclusive: nil)
    }

    public func contains(_ version: SemanticVersion) -> Bool {
        if version < min { return false }
        if let maxExclusive, version >= maxExclusive { return false }
        return true
    }
}
