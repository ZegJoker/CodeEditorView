import CryptoKit
import Foundation

/// Stable extension identifier (e.g. `com.example.hello`).
///
/// ## Grammar (EXT-001)
/// ```
/// segment  = [a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?
/// ext-id   = segment ("." segment)+
/// ```
/// Total length ≤ 214. Lowercase ASCII only. No path separators, NULs, or reserved names.
///
/// Filesystem layout must use ``directoryKey`` (hash of the canonical ID), never the raw ID
/// as a path component.
public struct ExtensionID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Validated initializer — throws on invalid grammar.
    public init(validating raw: String) throws {
        let canonical = raw.lowercased()
        try Self.validate(canonical)
        self.rawValue = canonical
    }

    /// `RawRepresentable` failable path — returns `nil` when invalid.
    public init?(rawValue: String) {
        guard let id = try? ExtensionID(validating: rawValue) else { return nil }
        self = id
    }

    /// String literal convenience for fixtures. **Traps** on invalid grammar — prefer
    /// ``init(validating:)`` at package/manifest boundaries.
    public init(stringLiteral value: String) {
        guard let id = try? ExtensionID(validating: value) else {
            fatalError("Invalid ExtensionID string literal (EXT-001): \(value)")
        }
        self = id
    }

    /// Stable filesystem directory key derived from the canonical ID (never use rawValue in paths).
    public var directoryKey: String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ raw: String) throws {
        guard !raw.isEmpty, raw.count <= 214 else {
            throw ExtensionIdentityError.invalidID(raw)
        }
        // Reject separators / control characters early.
        if raw.contains("/") || raw.contains("\\") || raw.contains(":")
            || raw.contains("\0") || raw.contains("..")
        {
            throw ExtensionIdentityError.invalidID(raw)
        }
        let segments = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2 else {
            throw ExtensionIdentityError.invalidID(raw)
        }
        let segmentPattern = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#
        let regex = try! NSRegularExpression(pattern: segmentPattern)
        let reserved = Set(["con", "prn", "aux", "nul", "com1", "lpt1", ".", ".."])
        for segment in segments {
            if reserved.contains(segment) {
                throw ExtensionIdentityError.invalidID(raw)
            }
            let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            guard regex.firstMatch(in: segment, options: [], range: range) != nil else {
                throw ExtensionIdentityError.invalidID(raw)
            }
        }
    }
}

public enum ExtensionIdentityError: Error, Sendable, Equatable {
    case invalidID(String)
    case invalidVersion(String)
}

/// Semantic version for manifests and host API negotiation (SemVer 2.0 core: MAJOR.MINOR.PATCH).
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

    /// Strict parse of SemVer core (`MAJOR`, `MAJOR.MINOR`, or `MAJOR.MINOR.PATCH`).
    /// Rejects non-numeric components, leading zeros, prerelease/build metadata, and extra segments.
    /// Does **not** silently coerce invalid fields to zero.
    public static func parse(_ string: String) -> SemanticVersion? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        func parseComponent(_ s: String) -> Int? {
            guard !s.isEmpty, s.allSatisfy(\.isNumber) else { return nil }
            if s.count > 1 && s.hasPrefix("0") { return nil }
            return Int(s)
        }
        guard let major = parseComponent(parts[0]) else { return nil }
        let minor = parts.count > 1 ? parseComponent(parts[1]) : 0
        let patch = parts.count > 2 ? parseComponent(parts[2]) : 0
        guard let minor, let patch else { return nil }
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
