/// Explicit capability matrix for a shipping or test host profile.
///
/// Process-backed APIs must call ``requireLocal(_:)`` (or check availability)
/// before starting work so iOS / App Store builds never appear to support
/// local processes and fail later through incidental Foundation errors.
public struct PlatformCapabilityProfile: Sendable, Hashable {
    public let platform: HostPlatform
    public let name: String
    public let shippingProfileID: ShippingProfileID?
    public let capabilities: [PlatformCapabilityKind: CapabilityAvailability]
    /// Present when ``shippingProfileID`` is ``ShippingProfileID/enterprise``.
    public let enterpriseOptions: EnterpriseProfileOptions?

    public init(
        platform: HostPlatform,
        name: String,
        shippingProfileID: ShippingProfileID? = nil,
        capabilities: [PlatformCapabilityKind: CapabilityAvailability],
        enterpriseOptions: EnterpriseProfileOptions? = nil
    ) {
        self.platform = platform
        self.name = name
        self.shippingProfileID = shippingProfileID
        self.capabilities = capabilities
        self.enterpriseOptions = enterpriseOptions
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

    /// Whether remote tooling may be used when local process tools are denied.
    public var remoteToolingAvailable: Bool {
        switch availability(for: .remoteTooling) {
        case .local, .remote, .hostProvided: return true
        default: return false
        }
    }

    // MARK: - Named presets (ADR-016 / Phase 15)

    /// Broadest library default for direct-distribution macOS.
    public static let directMacOS = PlatformCapabilityProfile(
        platform: .macOS,
        name: "direct-macos",
        shippingProfileID: .directMacOS,
        capabilities: [
            .localProcess: .local,
            .localPTY: .local,
            .localGitCLI: .local,
            .localLanguageServerProcess: .local,
            .nativeExtensionProcess: .local,
            .networkClient: .local,
            .workspaceFilesystem: .local,
            .bundledWasm: .local,
            .downloadableWasm: .local,
            .dynamicExtensionInstall: .local,
            .remoteTooling: .local,
            .extensionRegistry: .local,
        ]
    )

    /// Mac App Store-oriented defaults: no downloadable native helpers or marketplace Wasm.
    public static let macAppStore = PlatformCapabilityProfile(
        platform: .macOS,
        name: "mac-app-store",
        shippingProfileID: .macAppStore,
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
            .bundledWasm: .local,
            .downloadableWasm: .unavailable(
                reason: "Marketplace downloadable Wasm is not part of the default MAS profile"
            ),
            .dynamicExtensionInstall: .dataOnly,
            .remoteTooling: .local,
            .extensionRegistry: .dataOnly,
        ]
    )

    /// iOS / iPadOS App Store defaults — no local process tooling; remote LS/tooling.
    public static let iOS = PlatformCapabilityProfile(
        platform: .iOS,
        name: "ios",
        shippingProfileID: .iOS,
        capabilities: [
            .localProcess: .unavailable(reason: "Local process launch is not available on iOS"),
            .localPTY: .unavailable(reason: "Local PTY is not available on iOS"),
            .localGitCLI: .unavailable(reason: "Git CLI is not available on iOS"),
            .localLanguageServerProcess: .remote,
            .nativeExtensionProcess: .unavailable(reason: "Native extension helpers cannot be installed on iOS"),
            .networkClient: .local,
            .workspaceFilesystem: .hostProvided,
            .bundledWasm: .local,
            .downloadableWasm: .unavailable(
                reason: "Downloadable Wasm that changes functionality is not in the iOS stable promise"
            ),
            .dynamicExtensionInstall: .dataOnly,
            .remoteTooling: .local,
            .extensionRegistry: .unavailable(
                reason: "Remote marketplace install is not part of the default iOS profile"
            ),
        ]
    )

    /// Enterprise / internal: full local surface with managed-registry discipline.
    public static let enterprise = PlatformCapabilityProfile(
        platform: .macOS,
        name: "enterprise",
        shippingProfileID: .enterprise,
        capabilities: [
            .localProcess: .local,
            .localPTY: .local,
            .localGitCLI: .local,
            .localLanguageServerProcess: .local,
            .nativeExtensionProcess: .local,
            .networkClient: .local,
            .workspaceFilesystem: .local,
            .bundledWasm: .local,
            .downloadableWasm: .local,
            .dynamicExtensionInstall: .local,
            .remoteTooling: .local,
            .extensionRegistry: .local,
        ],
        enterpriseOptions: .default
    )

    /// Deterministic tests: local tools available; registry is file://-oriented in hosts.
    public static let test = PlatformCapabilityProfile(
        platform: HostPlatform.current,
        name: "test",
        shippingProfileID: .test,
        capabilities: [
            .localProcess: .local,
            .localPTY: .local,
            .localGitCLI: .local,
            .localLanguageServerProcess: .local,
            .nativeExtensionProcess: .local,
            .networkClient: .local,
            .workspaceFilesystem: .local,
            .bundledWasm: .local,
            .downloadableWasm: .local,
            .dynamicExtensionInstall: .local,
            .remoteTooling: .local,
            .extensionRegistry: .local,
        ]
    )

    /// Profile that denies all local process-like capabilities (iOS-like injection on any host).
    public static let processUnavailable = PlatformCapabilityProfile(
        platform: HostPlatform.current,
        name: "process-unavailable",
        shippingProfileID: nil,
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
            .bundledWasm: .unavailable(reason: "Injected test profile denies bundledWasm"),
            .downloadableWasm: .unavailable(reason: "Injected test profile denies downloadableWasm"),
            .dynamicExtensionInstall: .unavailable(reason: "Injected test profile denies install"),
            .remoteTooling: .unavailable(reason: "Injected test profile denies remoteTooling"),
            .extensionRegistry: .unavailable(reason: "Injected test profile denies registry"),
        ]
    )

    /// Resolve preset from shipping profile id.
    public static func shipping(_ id: ShippingProfileID) -> PlatformCapabilityProfile {
        switch id {
        case .directMacOS: return .directMacOS
        case .macAppStore: return .macAppStore
        case .iOS: return .iOS
        case .enterprise: return .enterprise
        case .test: return .test
        }
    }

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
                shippingProfileID: nil,
                capabilities: [
                    .localProcess: .unavailable(reason: "Unsupported host platform"),
                    .localPTY: .unavailable(reason: "Unsupported host platform"),
                    .localGitCLI: .unavailable(reason: "Unsupported host platform"),
                    .localLanguageServerProcess: .unavailable(reason: "Unsupported host platform"),
                    .nativeExtensionProcess: .unavailable(reason: "Unsupported host platform"),
                    .networkClient: .unavailable(reason: "Unsupported host platform"),
                    .workspaceFilesystem: .unavailable(reason: "Unsupported host platform"),
                    .bundledWasm: .unavailable(reason: "Unsupported host platform"),
                    .downloadableWasm: .unavailable(reason: "Unsupported host platform"),
                    .dynamicExtensionInstall: .unavailable(reason: "Unsupported host platform"),
                    .remoteTooling: .unavailable(reason: "Unsupported host platform"),
                    .extensionRegistry: .unavailable(reason: "Unsupported host platform"),
                ]
            )
        }
    }

    /// JSON-serializable snapshot for matrix scripts / fixtures.
    public func matrixSnapshot() -> [String: String] {
        var out: [String: String] = [:]
        for kind in PlatformCapabilityKind.allCases {
            out[kind.rawValue] = Self.encodeAvailability(availability(for: kind))
        }
        return out
    }

    public static func encodeAvailability(_ a: CapabilityAvailability) -> String {
        switch a {
        case .local: return "local"
        case .remote: return "remote"
        case .hostProvided: return "hostProvided"
        case .dataOnly: return "dataOnly"
        case .unavailable: return "unavailable"
        }
    }
}
