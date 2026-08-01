import Foundation
import CodeEditorCore

// MARK: - Runtime kind DTO (transport-neutral; Host owns full enum)

public enum ExtensionRuntimeKindDTO: String, Sendable, Hashable, Codable, CaseIterable {
    case dataOnly
    case builtIn
    case nativeProcess
    case swiftWasm
    case remote
}

// MARK: - Dynamic install / executable policy

public enum DynamicInstallationPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Any package kind allowed by trust policy may install.
    case full
    /// Only data-only packages (no native/Wasm executable artifacts).
    case dataOnly
    /// Only app-bundled artifacts (no marketplace install).
    case bundledOnly
    /// Runtime install disabled.
    case disabled
}

public enum ExecutableExtensionPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Trusted native helpers and Wasm (download subject to profile).
    case trustedNativeAndWasm
    /// Bundled Wasm only; no native helpers.
    case bundledWasmOnly
    /// Remote providers only for procedural work.
    case remoteOnly
    /// Data contributions + built-in Swift only.
    case dataAndBuiltInOnly
}

// MARK: - Artifact origin

public enum ExtensionArtifactOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case bundled
    case installed
    case workspaceDev
    case remote
}

// MARK: - Capability availability DTO (Codable-friendly)

public enum CapabilityAvailabilityDTO: String, Sendable, Hashable, Codable {
    case local
    case remote
    case hostProvided
    case dataOnly
    case unavailable

    public init(_ value: CapabilityAvailability) {
        switch value {
        case .local: self = .local
        case .remote: self = .remote
        case .hostProvided: self = .hostProvided
        case .dataOnly: self = .dataOnly
        case .unavailable: self = .unavailable
        }
    }
}

// MARK: - Extension host profile (plan §11.6)

public struct ExtensionHostProfile: Sendable, Hashable, Codable {
    public var shippingProfileID: ShippingProfileID
    public var platform: HostPlatform
    public var allowedRuntimes: Set<ExtensionRuntimeKindDTO>
    public var dynamicInstallation: DynamicInstallationPolicy
    public var executableExtensionPolicy: ExecutableExtensionPolicy
    public var localProcessSupport: CapabilityAvailabilityDTO
    public var localPTYSupport: CapabilityAvailabilityDTO
    public var remoteFallbackAvailable: Bool
    public var enterpriseOptions: EnterpriseProfileOptions?

    public init(
        shippingProfileID: ShippingProfileID,
        platform: HostPlatform,
        allowedRuntimes: Set<ExtensionRuntimeKindDTO>,
        dynamicInstallation: DynamicInstallationPolicy,
        executableExtensionPolicy: ExecutableExtensionPolicy,
        localProcessSupport: CapabilityAvailabilityDTO,
        localPTYSupport: CapabilityAvailabilityDTO,
        remoteFallbackAvailable: Bool,
        enterpriseOptions: EnterpriseProfileOptions? = nil
    ) {
        self.shippingProfileID = shippingProfileID
        self.platform = platform
        self.allowedRuntimes = allowedRuntimes
        self.dynamicInstallation = dynamicInstallation
        self.executableExtensionPolicy = executableExtensionPolicy
        self.localProcessSupport = localProcessSupport
        self.localPTYSupport = localPTYSupport
        self.remoteFallbackAvailable = remoteFallbackAvailable
        self.enterpriseOptions = enterpriseOptions
    }

    /// Build host profile from a platform capability matrix (Phase 15 single source of truth).
    public static func from(platformProfile: PlatformCapabilityProfile) -> ExtensionHostProfile {
        let id = platformProfile.shippingProfileID ?? .test
        let dyn: DynamicInstallationPolicy
        switch platformProfile.availability(for: .dynamicExtensionInstall) {
        case .local: dyn = .full
        case .dataOnly: dyn = .dataOnly
        case .unavailable, .remote, .hostProvided: dyn = .disabled
        }
        // Bundled-only when install is data-only and downloadable Wasm is unavailable
        let dynFinal: DynamicInstallationPolicy = {
            if dyn == .dataOnly,
               case .unavailable = platformProfile.availability(for: .downloadableWasm),
               case .unavailable = platformProfile.availability(for: .nativeExtensionProcess) {
                // MAS-like: data install + bundled wasm, not marketplace executables
                return .dataOnly
            }
            if dyn == .disabled { return .disabled }
            return dyn
        }()

        let exec: ExecutableExtensionPolicy
        let nativeLocal = platformProfile.availability(for: .nativeExtensionProcess).isLocallyAvailable
        let bundledWasm = platformProfile.availability(for: .bundledWasm).isLocallyAvailable
        let downloadWasm = platformProfile.availability(for: .downloadableWasm).isLocallyAvailable
        if nativeLocal && (bundledWasm || downloadWasm) {
            exec = .trustedNativeAndWasm
        } else if bundledWasm && !nativeLocal {
            exec = .bundledWasmOnly
        } else if platformProfile.remoteToolingAvailable && !nativeLocal && !bundledWasm {
            exec = .remoteOnly
        } else if !nativeLocal && !bundledWasm && !downloadWasm {
            exec = .dataAndBuiltInOnly
        } else {
            exec = .bundledWasmOnly
        }

        var runtimes: Set<ExtensionRuntimeKindDTO> = [.dataOnly, .builtIn]
        if nativeLocal { runtimes.insert(.nativeProcess) }
        if bundledWasm || downloadWasm { runtimes.insert(.swiftWasm) }
        if platformProfile.remoteToolingAvailable { runtimes.insert(.remote) }

        return ExtensionHostProfile(
            shippingProfileID: id,
            platform: platformProfile.platform,
            allowedRuntimes: runtimes,
            dynamicInstallation: dynFinal,
            executableExtensionPolicy: exec,
            localProcessSupport: CapabilityAvailabilityDTO(platformProfile.availability(for: .localProcess)),
            localPTYSupport: CapabilityAvailabilityDTO(platformProfile.availability(for: .localPTY)),
            remoteFallbackAvailable: platformProfile.remoteToolingAvailable,
            enterpriseOptions: platformProfile.enterpriseOptions
        )
    }

    public static func shipping(_ id: ShippingProfileID) -> ExtensionHostProfile {
        .from(platformProfile: .shipping(id))
    }
}

// MARK: - Store install policy

public struct ShippingInstallPolicy: Sendable, Hashable, Codable {
    public var dynamicInstallation: DynamicInstallationPolicy
    public var executableExtensionPolicy: ExecutableExtensionPolicy
    public var allowDownloadableWasm: Bool
    public var allowNativeHelpers: Bool
    public var allowRegistryFetch: Bool
    public var dataOnlyOnly: Bool
    public var shippingProfileID: ShippingProfileID

    public init(
        dynamicInstallation: DynamicInstallationPolicy,
        executableExtensionPolicy: ExecutableExtensionPolicy,
        allowDownloadableWasm: Bool,
        allowNativeHelpers: Bool,
        allowRegistryFetch: Bool,
        dataOnlyOnly: Bool,
        shippingProfileID: ShippingProfileID
    ) {
        self.dynamicInstallation = dynamicInstallation
        self.executableExtensionPolicy = executableExtensionPolicy
        self.allowDownloadableWasm = allowDownloadableWasm
        self.allowNativeHelpers = allowNativeHelpers
        self.allowRegistryFetch = allowRegistryFetch
        self.dataOnlyOnly = dataOnlyOnly
        self.shippingProfileID = shippingProfileID
    }

    public static func from(hostProfile: ExtensionHostProfile, platform: PlatformCapabilityProfile) -> ShippingInstallPolicy {
        ShippingInstallPolicy(
            dynamicInstallation: hostProfile.dynamicInstallation,
            executableExtensionPolicy: hostProfile.executableExtensionPolicy,
            allowDownloadableWasm: platform.availability(for: .downloadableWasm).isLocallyAvailable,
            allowNativeHelpers: platform.availability(for: .nativeExtensionProcess).isLocallyAvailable,
            allowRegistryFetch: {
                switch platform.availability(for: .extensionRegistry) {
                case .local, .dataOnly: return true
                default: return false
                }
            }(),
            dataOnlyOnly: hostProfile.dynamicInstallation == .dataOnly
                || hostProfile.dynamicInstallation == .bundledOnly,
            shippingProfileID: hostProfile.shippingProfileID
        )
    }

    public static func shipping(_ id: ShippingProfileID) -> ShippingInstallPolicy {
        let platform = PlatformCapabilityProfile.shipping(id)
        return .from(hostProfile: .from(platformProfile: platform), platform: platform)
    }
}

// MARK: - Runnability descriptors (no SwiftUI)

public enum ArtifactRunDecision: String, Sendable, Hashable, Codable {
    case allow
    case deny
}

public struct ArtifactRunnabilityDescriptor: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var packageID: String
    public var requestedRuntime: ExtensionRuntimeKindDTO?
    public var decision: ArtifactRunDecision
    public var reasons: [String]
    public var remoteFallbackAvailable: Bool
    public var suggestedAction: String?

    public init(
        id: String = UUID().uuidString,
        packageID: String,
        requestedRuntime: ExtensionRuntimeKindDTO? = nil,
        decision: ArtifactRunDecision,
        reasons: [String] = [],
        remoteFallbackAvailable: Bool = false,
        suggestedAction: String? = nil
    ) {
        self.id = id
        self.packageID = packageID
        self.requestedRuntime = requestedRuntime
        self.decision = decision
        self.reasons = reasons
        self.remoteFallbackAvailable = remoteFallbackAvailable
        self.suggestedAction = suggestedAction
    }
}

/// Pure evaluation of whether a package may run under a host profile.
public enum ArtifactRunnability {
    public static func evaluate(
        packageID: String,
        origin: ExtensionArtifactOrigin,
        requestedRuntime: ExtensionRuntimeKindDTO,
        hostProfile: ExtensionHostProfile,
        hasRemoteDescriptor: Bool = false
    ) -> ArtifactRunnabilityDescriptor {
        var reasons: [String] = []
        if !hostProfile.allowedRuntimes.contains(requestedRuntime) {
            reasons.append("Runtime \(requestedRuntime.rawValue) not allowed on \(hostProfile.shippingProfileID.rawValue)")
        }
        switch requestedRuntime {
        case .nativeProcess:
            if hostProfile.executableExtensionPolicy == .bundledWasmOnly
                || hostProfile.executableExtensionPolicy == .remoteOnly
                || hostProfile.executableExtensionPolicy == .dataAndBuiltInOnly {
                reasons.append("Executable policy \(hostProfile.executableExtensionPolicy.rawValue) denies native helpers")
            }
            if origin == .workspaceDev,
               hostProfile.enterpriseOptions?.requireSignedNativeHelpers == true {
                reasons.append("Enterprise profile requires signed native helpers")
            }
        case .swiftWasm:
            if origin == .installed || origin == .remote {
                if hostProfile.executableExtensionPolicy == .bundledWasmOnly
                    || hostProfile.executableExtensionPolicy == .dataAndBuiltInOnly
                    || hostProfile.executableExtensionPolicy == .remoteOnly {
                    reasons.append("Downloadable/marketplace Wasm denied by executable policy")
                }
            }
            if origin == .bundled,
               hostProfile.executableExtensionPolicy == .dataAndBuiltInOnly
                || hostProfile.executableExtensionPolicy == .remoteOnly {
                reasons.append("Wasm not allowed under \(hostProfile.executableExtensionPolicy.rawValue)")
            }
        case .remote:
            if !hostProfile.allowedRuntimes.contains(.remote) {
                reasons.append("Remote runtime not in allowed set")
            }
        case .dataOnly, .builtIn:
            break
        }
        let remoteOK = hostProfile.remoteFallbackAvailable && hasRemoteDescriptor
        if reasons.isEmpty {
            return ArtifactRunnabilityDescriptor(
                packageID: packageID,
                requestedRuntime: requestedRuntime,
                decision: .allow,
                reasons: [],
                remoteFallbackAvailable: remoteOK
            )
        }
        return ArtifactRunnabilityDescriptor(
            packageID: packageID,
            requestedRuntime: requestedRuntime,
            decision: .deny,
            reasons: reasons,
            remoteFallbackAvailable: remoteOK,
            suggestedAction: remoteOK
                ? "Use remote tooling fallback for this package"
                : "Install a data-only or built-in variant, or switch shipping profile"
        )
    }
}
