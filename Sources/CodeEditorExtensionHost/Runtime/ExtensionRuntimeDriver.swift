import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import Foundation

public enum ExtensionRuntimeKind: String, Sendable, Hashable, Codable {
    case dataOnly
    case builtIn
    case nativeProcess
    case swiftWasm
    case remote
}

public enum ExtensionInstanceState: String, Sendable, Hashable, Codable {
    case discovered
    case validating
    case ready
    case activating
    case active
    case deactivating
    case failed
    case quarantined
    case stopped
}

public enum ExtensionStopReason: String, Sendable, Hashable, Codable {
    case user
    case hostShutdown
    case crash
    case quarantine
    case update
    case error
}

public enum ExtensionInstanceEvent: Sendable, Equatable {
    case state(ExtensionInstanceState)
    case log(String)
    case crashed(String)
    case quarantined(String)
    case trace(ConformanceEvent)
}

public struct PreparedExtensionPackage: Sendable {
    public var packageID: ExtensionID
    public var displayName: String
    public var version: SemanticVersion
    public var manifest: ExtensionManifest
    public var packageRoot: URL?
    public var digest: String?
    public var nativeExecutable: URL?
    public var wasmModuleURL: URL?
    public var wasmModuleData: Data?
    public var trustClass: ExtensionTrustClass
    public var runtimePreference: ExtensionRuntimeKind?
    public var builtInExtension: (any CodeEditorExtension)?
    /// Provenance used for profile gates (bundled vs marketplace install).
    public var origin: ExtensionArtifactOrigin
    /// When true, a remote provider peer is registered for this package.
    public var hasRemoteDescriptor: Bool

    public init(
        packageID: ExtensionID,
        displayName: String,
        version: SemanticVersion,
        manifest: ExtensionManifest,
        packageRoot: URL? = nil,
        digest: String? = nil,
        nativeExecutable: URL? = nil,
        wasmModuleURL: URL? = nil,
        wasmModuleData: Data? = nil,
        trustClass: ExtensionTrustClass = .workspaceDev,
        runtimePreference: ExtensionRuntimeKind? = nil,
        builtInExtension: (any CodeEditorExtension)? = nil,
        origin: ExtensionArtifactOrigin = .installed,
        hasRemoteDescriptor: Bool = false
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.version = version
        self.manifest = manifest
        self.packageRoot = packageRoot
        self.digest = digest
        self.nativeExecutable = nativeExecutable
        self.wasmModuleURL = wasmModuleURL
        self.wasmModuleData = wasmModuleData
        self.trustClass = trustClass
        self.runtimePreference = runtimePreference
        self.builtInExtension = builtInExtension
        self.origin = origin
        self.hasRemoteDescriptor = hasRemoteDescriptor
    }

    public var runtimeKindDTO: ExtensionRuntimeKindDTO? {
        runtimePreference.map { $0.dto }
    }
}

extension ExtensionRuntimeKind {
    public var dto: ExtensionRuntimeKindDTO {
        switch self {
        case .dataOnly: return .dataOnly
        case .builtIn: return .builtIn
        case .nativeProcess: return .nativeProcess
        case .swiftWasm: return .swiftWasm
        case .remote: return .remote
        }
    }

    public init(dto: ExtensionRuntimeKindDTO) {
        switch dto {
        case .dataOnly: self = .dataOnly
        case .builtIn: self = .builtIn
        case .nativeProcess: self = .nativeProcess
        case .swiftWasm: self = .swiftWasm
        case .remote: self = .remote
        }
    }
}

public struct PreparedExtension: Sendable {
    public var package: PreparedExtensionPackage
    public var kind: ExtensionRuntimeKind

    public init(package: PreparedExtensionPackage, kind: ExtensionRuntimeKind) {
        self.package = package
        self.kind = kind
    }
}

public struct ExtensionHostHandshake: Sendable {
    public var environment: HostEnvironment
    public var limits: ExtensionHostLimits
    public var generation: UInt64
    public var requireSchemaMatch: Bool

    public init(
        environment: HostEnvironment = .full,
        limits: ExtensionHostLimits = .default,
        generation: UInt64 = 1,
        requireSchemaMatch: Bool = true
    ) {
        self.environment = environment
        self.limits = limits
        self.generation = generation
        self.requireSchemaMatch = requireSchemaMatch
    }
}

public struct ExtensionExecutionPolicy: Sendable {
    public var trust: ExtensionTrustPolicy
    public var prefersSandbox: Bool
    public var allowsRemoteProviders: Bool
    public var maxRestarts: Int
    public var restartBackoffMS: [Int]
    public var quarantineCrashThreshold: Int
    public var platformAllowsNativeProcess: Bool
    public var shippingProfileID: ShippingProfileID?
    public var platformProfile: PlatformCapabilityProfile
    public var hostProfile: ExtensionHostProfile
    public var allowDownloadableWasm: Bool
    public var allowBundledWasm: Bool

    public init(
        trust: ExtensionTrustPolicy = .strict,
        prefersSandbox: Bool = false,
        allowsRemoteProviders: Bool = false,
        maxRestarts: Int = 3,
        restartBackoffMS: [Int] = [100, 500, 2000],
        quarantineCrashThreshold: Int = 3,
        platformAllowsNativeProcess: Bool = true,
        shippingProfileID: ShippingProfileID? = nil,
        platformProfile: PlatformCapabilityProfile = .default(),
        hostProfile: ExtensionHostProfile? = nil,
        allowDownloadableWasm: Bool? = nil,
        allowBundledWasm: Bool? = nil
    ) {
        self.trust = trust
        self.prefersSandbox = prefersSandbox
        self.allowsRemoteProviders = allowsRemoteProviders
        self.maxRestarts = maxRestarts
        self.restartBackoffMS = restartBackoffMS
        self.quarantineCrashThreshold = quarantineCrashThreshold
        self.platformAllowsNativeProcess = platformAllowsNativeProcess
        self.shippingProfileID = shippingProfileID ?? platformProfile.shippingProfileID
        self.platformProfile = platformProfile
        self.hostProfile = hostProfile ?? .from(platformProfile: platformProfile)
        self.allowDownloadableWasm =
            allowDownloadableWasm ?? platformProfile.availability(for: .downloadableWasm).isLocallyAvailable
        self.allowBundledWasm =
            allowBundledWasm ?? platformProfile.availability(for: .bundledWasm).isLocallyAvailable
    }

    public static let testing = ExtensionExecutionPolicy(
        trust: .testing,
        allowsRemoteProviders: true,
        platformAllowsNativeProcess: true,
        shippingProfileID: .test,
        platformProfile: .test,
        hostProfile: .shipping(.test)
    )

    /// Shipping binary configuration for profile A–E (fail-closed matrix).
    public static func shipping(
        _ id: ShippingProfileID,
        trust: ExtensionTrustPolicy? = nil
    ) -> ExtensionExecutionPolicy {
        let platform = PlatformCapabilityProfile.shipping(id)
        let host = ExtensionHostProfile.from(platformProfile: platform)
        let trustPolicy: ExtensionTrustPolicy
        if let trust {
            trustPolicy = trust
        } else {
            switch id {
            case .test:
                trustPolicy = .testing
            case .directMacOS:
                var t = ExtensionTrustPolicy.strict
                t.allowWorkspaceDevNative = true
                trustPolicy = t
            case .enterprise:
                trustPolicy = .strict
            case .macAppStore, .iOS:
                trustPolicy = .strict
            }
        }
        return ExtensionExecutionPolicy(
            trust: trustPolicy,
            prefersSandbox: id == .macAppStore || id == .iOS,
            allowsRemoteProviders: platform.remoteToolingAvailable,
            platformAllowsNativeProcess: platform.availability(for: .nativeExtensionProcess).isLocallyAvailable,
            shippingProfileID: id,
            platformProfile: platform,
            hostProfile: host
        )
    }
}

public protocol ExtensionRuntimeDriver: Sendable {
    var kind: ExtensionRuntimeKind { get }
    func prepare(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) async throws -> PreparedExtension
    func start(
        prepared: PreparedExtension,
        handshake: ExtensionHostHandshake,
        broker: CapabilityBroker
    ) async throws -> any ExtensionInstance
}

public protocol ExtensionInstance: Sendable {
    var identity: ExtensionID { get }
    var generation: UInt64 { get }
    var runtimeKind: ExtensionRuntimeKind { get }
    var state: ExtensionInstanceState { get async }
    var events: AsyncStream<ExtensionInstanceEvent> { get }
    func send(_ envelope: ExtensionEnvelope) async throws
    func request(_ method: ExtensionMethodID, payload: Data) async throws -> Data
    func cancel(_ requestID: ExtensionRequestID) async
    func stop(reason: ExtensionStopReason) async
}

public enum RuntimeSelectionError: Error, Sendable, Equatable {
    case noPermittedRuntime
    case wasmNotAvailable
    case nativeNotAllowed
    case missingArtifact
    case profileDenied(String)
    case remoteNotAllowed
}

public enum RuntimeSelector {
    public static func select(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) throws -> ExtensionRuntimeKind {
        if let pref = package.runtimePreference {
            return try selectPreferred(pref, package: package, policy: policy)
        }
        // Auto selection with hard profile gates (no soft-skip to built-in on denial).
        if package.builtInExtension != nil {
            return .builtIn
        }
        if package.hasRemoteDescriptor, policy.allowsRemoteProviders,
            policy.hostProfile.allowedRuntimes.contains(.remote)
        {
            // Prefer remote when local native/process is denied and remote is available.
            if !policy.platformAllowsNativeProcess {
                return .remote
            }
        }
        if package.wasmModuleData != nil || package.wasmModuleURL != nil {
            if policy.prefersSandbox || !policy.platformAllowsNativeProcess {
                try assertWasmAllowed(package: package, policy: policy)
                return .swiftWasm
            }
        }
        if package.nativeExecutable != nil {
            try assertNativeAllowed(package: package, policy: policy)
            return .nativeProcess
        }
        if package.wasmModuleData != nil || package.wasmModuleURL != nil {
            try assertWasmAllowed(package: package, policy: policy)
            return .swiftWasm
        }
        if package.hasRemoteDescriptor, policy.allowsRemoteProviders {
            return .remote
        }
        throw RuntimeSelectionError.noPermittedRuntime
    }

    private static func selectPreferred(
        _ pref: ExtensionRuntimeKind,
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) throws -> ExtensionRuntimeKind {
        guard
            policy.hostProfile.allowedRuntimes.contains(pref.dto)
                || pref == .dataOnly || pref == .builtIn
        else {
            // Explicit remote fallback when preferred runtime denied
            if package.hasRemoteDescriptor, policy.allowsRemoteProviders,
                policy.hostProfile.allowedRuntimes.contains(.remote)
            {
                return .remote
            }
            throw RuntimeSelectionError.profileDenied(
                "Runtime \(pref.rawValue) not allowed on \(policy.hostProfile.shippingProfileID.rawValue)"
            )
        }
        switch pref {
        case .dataOnly:
            return .dataOnly
        case .builtIn:
            if package.builtInExtension != nil { return .builtIn }
            throw RuntimeSelectionError.missingArtifact
        case .nativeProcess:
            try assertNativeAllowed(package: package, policy: policy)
            guard package.nativeExecutable != nil else { throw RuntimeSelectionError.missingArtifact }
            return .nativeProcess
        case .swiftWasm:
            try assertWasmAllowed(package: package, policy: policy)
            guard package.wasmModuleData != nil || package.wasmModuleURL != nil else {
                throw RuntimeSelectionError.missingArtifact
            }
            return .swiftWasm
        case .remote:
            guard policy.allowsRemoteProviders else { throw RuntimeSelectionError.remoteNotAllowed }
            return .remote
        }
    }

    private static func assertNativeAllowed(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) throws {
        let decision = NativeHelperLaunchPolicy.evaluate(
            trustClass: package.trustClass,
            origin: package.origin,
            policy: policy
        )
        guard decision.allowed else {
            throw RuntimeSelectionError.nativeNotAllowed
        }
        try ExtensionPackageVerifier.assertNativeLaunchAllowed(
            trust: package.trustClass,
            policy: policy.trust
        )
        guard policy.platformAllowsNativeProcess else {
            throw RuntimeSelectionError.nativeNotAllowed
        }
    }

    private static func assertWasmAllowed(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) throws {
        switch package.origin {
        case .bundled:
            guard policy.allowBundledWasm else {
                throw RuntimeSelectionError.profileDenied("bundled Wasm denied by shipping profile")
            }
        case .installed, .remote:
            guard policy.allowDownloadableWasm else {
                throw RuntimeSelectionError.profileDenied("downloadable Wasm denied by shipping profile")
            }
        case .workspaceDev:
            // Dev Wasm treated as downloadable unless profile allows bundled-only testing.
            if !policy.allowDownloadableWasm && !policy.allowBundledWasm {
                throw RuntimeSelectionError.profileDenied("Wasm denied by shipping profile")
            }
            if !policy.allowDownloadableWasm, policy.allowBundledWasm {
                // workspace-dev may still use bundled path when only bundled allowed
                break
            }
        }
    }
}
