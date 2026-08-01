/// Named shipping feature profiles (ADR-016 / plan §11).
///
/// Hosts select one of these at build or runtime configuration so each binary
/// exposes only its approved capabilities.
public enum ShippingProfileID: String, Sendable, Hashable, Codable, CaseIterable {
    /// Direct-distribution macOS (broadest functional profile).
    case directMacOS = "direct-macos"
    /// Mac App Store defaults (no downloadable native helpers / marketplace Wasm).
    case macAppStore = "mac-app-store"
    /// iOS / iPadOS App Store defaults.
    case iOS = "ios"
    /// Enterprise / internal distribution (managed registry, org-signed helpers).
    case enterprise = "enterprise"
    /// Deterministic tests / embedded hosts (file:// registry, mock-friendly).
    case test = "test"

    public var displayName: String {
        switch self {
        case .directMacOS: return "Direct-distribution macOS"
        case .macAppStore: return "Mac App Store"
        case .iOS: return "iOS/iPadOS App Store"
        case .enterprise: return "Enterprise/internal"
        case .test: return "Tests/embedded"
        }
    }

    public var hostPlatform: HostPlatform {
        switch self {
        case .directMacOS, .macAppStore, .enterprise: return .macOS
        case .iOS: return .iOS
        case .test: return HostPlatform.current
        }
    }
}

/// Enterprise-specific policy knobs (still require audit/sandbox discipline).
public struct EnterpriseProfileOptions: Sendable, Hashable, Codable {
    /// Only managed/allowlisted registries may be used.
    public var managedRegistryOnly: Bool
    /// Publisher key must appear on an allowlist before native launch.
    public var publisherAllowlistRequired: Bool
    /// Native helpers must be trusted-signed (workspace-dev denied).
    public var requireSignedNativeHelpers: Bool

    public init(
        managedRegistryOnly: Bool = true,
        publisherAllowlistRequired: Bool = true,
        requireSignedNativeHelpers: Bool = true
    ) {
        self.managedRegistryOnly = managedRegistryOnly
        self.publisherAllowlistRequired = publisherAllowlistRequired
        self.requireSignedNativeHelpers = requireSignedNativeHelpers
    }

    public static let `default` = EnterpriseProfileOptions()
}
