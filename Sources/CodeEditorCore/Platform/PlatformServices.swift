import Foundation

// MARK: - Service protocols
//
// Products keep concrete adapters; hosts and tests inject fakes.
// These protocols are the Phase 1 seam for process/FS/network/PTY honesty.

/// Launches a local subprocess when ``PlatformCapabilityKind/localProcess`` (or a more specific kind) is granted.
public protocol ProcessLaunching: Sendable {
    func requireProcessCapability() throws
}

/// Pseudo-terminal access (full implementation in later terminal phases).
public protocol PTYAccess: Sendable {
    func requirePTYCapability() throws
}

/// Workspace-scoped filesystem operations.
public protocol FileSystemAccess: Sendable {
    func requireFilesystemCapability() throws
}

/// Outbound network access (downloads, registry).
public protocol NetworkAccess: Sendable {
    func requireNetworkCapability() throws
}

/// Default capability-checked process launcher using a profile.
public struct ProfileProcessLauncher: ProcessLaunching, Sendable {
    public let profile: PlatformCapabilityProfile
    public let kind: PlatformCapabilityKind

    public init(
        profile: PlatformCapabilityProfile = .default(),
        kind: PlatformCapabilityKind = .localProcess
    ) {
        self.profile = profile
        self.kind = kind
    }

    public func requireProcessCapability() throws {
        try profile.requireLocal(kind)
    }
}

/// Bundle of host platform services used by tooling products.
public struct PlatformServices: Sendable {
    public var profile: PlatformCapabilityProfile
    public var process: any ProcessLaunching
    public var pty: any PTYAccess
    public var filesystem: any FileSystemAccess
    public var network: any NetworkAccess

    public init(
        profile: PlatformCapabilityProfile = .default(),
        process: (any ProcessLaunching)? = nil,
        pty: (any PTYAccess)? = nil,
        filesystem: (any FileSystemAccess)? = nil,
        network: (any NetworkAccess)? = nil
    ) {
        self.profile = profile
        self.process = process ?? ProfileProcessLauncher(profile: profile, kind: .localProcess)
        self.pty = pty ?? ProfilePTYAccess(profile: profile)
        self.filesystem = filesystem ?? ProfileFileSystemAccess(profile: profile)
        self.network = network ?? ProfileNetworkAccess(profile: profile)
    }

    public static func `default`(for platform: HostPlatform = .current) -> PlatformServices {
        PlatformServices(profile: .default(for: platform))
    }
}

public struct ProfilePTYAccess: PTYAccess, Sendable {
    public let profile: PlatformCapabilityProfile
    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }
    public func requirePTYCapability() throws {
        try profile.requireLocal(.localPTY)
    }
}

public struct ProfileFileSystemAccess: FileSystemAccess, Sendable {
    public let profile: PlatformCapabilityProfile
    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }
    public func requireFilesystemCapability() throws {
        switch profile.availability(for: .workspaceFilesystem) {
        case .local, .hostProvided:
            return
        case .remote:
            throw CodeEditorPlatformError.unsupportedCapability(
                kind: .workspaceFilesystem,
                reason: "Filesystem is remote-only on profile \(profile.name)"
            )
        case .dataOnly:
            throw CodeEditorPlatformError.unsupportedCapability(
                kind: .workspaceFilesystem,
                reason: "Filesystem is data-only on profile \(profile.name)"
            )
        case .unavailable(let reason):
            throw CodeEditorPlatformError.unsupportedCapability(kind: .workspaceFilesystem, reason: reason)
        }
    }
}

public struct ProfileNetworkAccess: NetworkAccess, Sendable {
    public let profile: PlatformCapabilityProfile
    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }
    public func requireNetworkCapability() throws {
        try profile.requireLocal(.networkClient)
    }
}
