import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions

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
        builtInExtension: (any CodeEditorExtension)? = nil
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

    public init(
        trust: ExtensionTrustPolicy = .strict,
        prefersSandbox: Bool = false,
        allowsRemoteProviders: Bool = false,
        maxRestarts: Int = 3,
        restartBackoffMS: [Int] = [100, 500, 2000],
        quarantineCrashThreshold: Int = 3,
        platformAllowsNativeProcess: Bool = true
    ) {
        self.trust = trust
        self.prefersSandbox = prefersSandbox
        self.allowsRemoteProviders = allowsRemoteProviders
        self.maxRestarts = maxRestarts
        self.restartBackoffMS = restartBackoffMS
        self.quarantineCrashThreshold = quarantineCrashThreshold
        self.platformAllowsNativeProcess = platformAllowsNativeProcess
    }

    public static let testing = ExtensionExecutionPolicy(
        trust: .testing,
        platformAllowsNativeProcess: true
    )
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
}

public enum RuntimeSelector {
    public static func select(
        package: PreparedExtensionPackage,
        policy: ExtensionExecutionPolicy
    ) throws -> ExtensionRuntimeKind {
        if let pref = package.runtimePreference {
            switch pref {
            case .dataOnly: return .dataOnly
            case .builtIn:
                if package.builtInExtension != nil { return .builtIn }
            case .nativeProcess:
                try ExtensionPackageVerifier.assertNativeLaunchAllowed(
                    trust: package.trustClass,
                    policy: policy.trust
                )
                guard policy.platformAllowsNativeProcess else { throw RuntimeSelectionError.nativeNotAllowed }
                guard package.nativeExecutable != nil else { throw RuntimeSelectionError.missingArtifact }
                return .nativeProcess
            case .swiftWasm:
                guard package.wasmModuleData != nil || package.wasmModuleURL != nil else {
                    throw RuntimeSelectionError.missingArtifact
                }
                return .swiftWasm
            case .remote:
                if policy.allowsRemoteProviders { return .remote }
            }
        }
        if package.builtInExtension != nil { return .builtIn }
        if package.wasmModuleData != nil || package.wasmModuleURL != nil {
            if policy.prefersSandbox { return .swiftWasm }
        }
        if package.nativeExecutable != nil, policy.platformAllowsNativeProcess {
            try ExtensionPackageVerifier.assertNativeLaunchAllowed(
                trust: package.trustClass,
                policy: policy.trust
            )
            return .nativeProcess
        }
        if package.wasmModuleData != nil || package.wasmModuleURL != nil {
            return .swiftWasm
        }
        throw RuntimeSelectionError.noPermittedRuntime
    }
}
