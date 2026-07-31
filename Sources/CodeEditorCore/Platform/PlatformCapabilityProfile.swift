/// Explicit capability matrix for a shipping or test host profile.
///
/// Process-backed APIs must call ``requireLocal(_:)`` (or check availability)
/// before starting work so iOS / App Store builds never appear to support
/// local processes and fail later through incidental Foundation errors.
public struct PlatformCapabilityProfile: Sendable, Hashable {
    public let platform: HostPlatform
    public let name: String
    public let capabilities: [PlatformCapabilityKind: CapabilityAvailability]

    public init(
        platform: HostPlatform,
        name: String,
        capabilities: [PlatformCapabilityKind: CapabilityAvailability]
    ) {
        self.platform = platform
        self.name = name
        self.capabilities = capabilities
    }

    public func availability(for kind: PlatformCapabilityKind) -> CapabilityAvailability {
        capabilities[kind] ?? .unavailable(reason: "Capability \(kind.rawValue) not declared on profile \(name)")
    }

    /// Throws ``CodeEditorPlatformError/unsupportedCapability`` unless the capability is `.local`.
    public func requireLocal(_ kind: PlatformCapabilityKind) throws {
        switch availability(for: kind) {
        case .local:
            return
        case .remote:
            throw CodeEditorPlatformError.unsupportedCapability(
                kind: kind,
                reason: "Profile \(name) offers \(kind.rawValue) only via remote providers"
            )
        case .hostProvided:
            throw CodeEditorPlatformError.unsupportedCapability(
                kind: kind,
                reason: "Profile \(name) requires a host-provided implementation for \(kind.rawValue)"
            )
        case .dataOnly:
            throw CodeEditorPlatformError.unsupportedCapability(
                kind: kind,
                reason: "Profile \(name) is data-only for \(kind.rawValue)"
            )
        case let .unavailable(reason):
            throw CodeEditorPlatformError.unsupportedCapability(kind: kind, reason: reason)
        }
    }

    // MARK: - Named presets (ADR-016)

    /// Broadest library default for direct-distribution macOS.
    public static let directMacOS = PlatformCapabilityProfile(
        platform: .macOS,
        name: "direct-macos",
        capabilities: [
            .localProcess: .local,
            .localPTY: .local,
            .localGitCLI: .local,
            .localLanguageServerProcess: .local,
            .nativeExtensionProcess: .local,
            .networkClient: .local,
            .workspaceFilesystem: .local,
        ]
    )

    /// Mac App Store-oriented defaults: local tools allowed only where sandbox typically permits;
    /// native downloadable helpers are unavailable (host may re-enable with entitlements).
    public static let macAppStore = PlatformCapabilityProfile(
        platform: .macOS,
        name: "mac-app-store",
        capabilities: [
            .localProcess: .local,
            .localPTY: .unavailable(reason: "PTY often restricted under App Sandbox; host must opt in"),
            .localGitCLI: .local,
            .localLanguageServerProcess: .local,
            .nativeExtensionProcess: .unavailable(
                reason: "Downloadable native extension helpers are not part of the default MAS profile"
            ),
            .networkClient: .local,
            .workspaceFilesystem: .local,
        ]
    )

    /// iOS / iPadOS App Store defaults — no local process tooling.
    public static let iOS = PlatformCapabilityProfile(
        platform: .iOS,
        name: "ios",
        capabilities: [
            .localProcess: .unavailable(reason: "Local process launch is not available on iOS"),
            .localPTY: .unavailable(reason: "Local PTY is not available on iOS"),
            .localGitCLI: .unavailable(reason: "Git CLI is not available on iOS"),
            .localLanguageServerProcess: .remote,
            .nativeExtensionProcess: .unavailable(reason: "Native extension helpers cannot be installed on iOS"),
            .networkClient: .local,
            .workspaceFilesystem: .hostProvided,
        ]
    )

    /// Enterprise / internal distribution: same local surface as direct macOS by default.
    public static let enterprise = PlatformCapabilityProfile(
        platform: .macOS,
        name: "enterprise",
        capabilities: PlatformCapabilityProfile.directMacOS.capabilities
    )

    /// Deterministic tests: local process capabilities available so unit tests can run on macOS CI.
    public static let test = PlatformCapabilityProfile(
        platform: HostPlatform.current,
        name: "test",
        capabilities: PlatformCapabilityProfile.directMacOS.capabilities
    )

    /// Profile that denies all local process-like capabilities (iOS-like injection on any host).
    public static let processUnavailable = PlatformCapabilityProfile(
        platform: HostPlatform.current,
        name: "process-unavailable",
        capabilities: [
            .localProcess: .unavailable(reason: "Injected test profile denies localProcess"),
            .localPTY: .unavailable(reason: "Injected test profile denies localPTY"),
            .localGitCLI: .unavailable(reason: "Injected test profile denies localGitCLI"),
            .localLanguageServerProcess: .unavailable(
                reason: "Injected test profile denies localLanguageServerProcess"
            ),
            .nativeExtensionProcess: .unavailable(
                reason: "Injected test profile denies nativeExtensionProcess"
            ),
            .networkClient: .local,
            .workspaceFilesystem: .local,
        ]
    )

    /// Default for the current OS: macOS → directMacOS, iOS → iOS, else unavailable process tools.
    public static func `default`(for platform: HostPlatform = .current) -> PlatformCapabilityProfile {
        switch platform {
        case .macOS:
            return .directMacOS
        case .iOS:
            return .iOS
        case .other:
            return PlatformCapabilityProfile(
                platform: .other,
                name: "other",
                capabilities: [
                    .localProcess: .unavailable(reason: "Unsupported host platform"),
                    .localPTY: .unavailable(reason: "Unsupported host platform"),
                    .localGitCLI: .unavailable(reason: "Unsupported host platform"),
                    .localLanguageServerProcess: .unavailable(reason: "Unsupported host platform"),
                    .nativeExtensionProcess: .unavailable(reason: "Unsupported host platform"),
                    .networkClient: .unavailable(reason: "Unsupported host platform"),
                    .workspaceFilesystem: .unavailable(reason: "Unsupported host platform"),
                ]
            )
        }
    }
}
