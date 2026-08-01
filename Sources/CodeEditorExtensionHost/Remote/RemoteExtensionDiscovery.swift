import CodeEditorExtensions
import Foundation

public enum RemoteExtensionLaunch: Sendable, Hashable {
    case process(executable: URL, arguments: [String])
    case testFactory(String)
    case extensionKit(bundleIdentifier: String)
}

public struct RemoteExtensionDescriptor: Sendable, Hashable {
    public var id: ExtensionID
    public var displayName: String
    public var manifest: ExtensionManifest
    public var launch: RemoteExtensionLaunch

    public init(
        id: ExtensionID,
        displayName: String,
        manifest: ExtensionManifest,
        launch: RemoteExtensionLaunch
    ) {
        self.id = id
        self.displayName = displayName
        self.manifest = manifest
        self.launch = launch
    }
}

public protocol RemoteExtensionDiscovery: Sendable {
    func discover() async throws -> [RemoteExtensionDescriptor]
}

public struct StaticRemoteExtensionDiscovery: RemoteExtensionDiscovery {
    public var descriptors: [RemoteExtensionDescriptor]

    public init(descriptors: [RemoteExtensionDescriptor] = []) {
        self.descriptors = descriptors
    }

    public func discover() async throws -> [RemoteExtensionDescriptor] {
        descriptors
    }
}

public enum ExtensionProcessState: String, Sendable, Hashable, Codable {
    case idle
    case starting
    case running
    case unhealthy
    case restarting
    case stopped
    case crashed
}

public struct RemoteExtensionStatus: Sendable, Hashable {
    public var id: ExtensionID
    public var displayName: String
    public var processState: ExtensionProcessState
    public var health: ExtensionProcessHealth
    public var lastError: String?
    public var grantedPermissions: Set<ExtensionPermission>

    public init(
        id: ExtensionID,
        displayName: String,
        processState: ExtensionProcessState,
        health: ExtensionProcessHealth = ExtensionProcessHealth(),
        lastError: String? = nil,
        grantedPermissions: Set<ExtensionPermission> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.processState = processState
        self.health = health
        self.lastError = lastError
        self.grantedPermissions = grantedPermissions
    }
}

public struct RemoteExtensionHostPolicy: Sendable, Hashable {
    public var requestTimeout: Duration
    public var maxResponseBytes: Int
    public var autoRestart: Bool
    public var maxRestarts: Int

    public init(
        requestTimeout: Duration = .seconds(15),
        maxResponseBytes: Int = 4 * 1024 * 1024,
        autoRestart: Bool = false,
        maxRestarts: Int = 3
    ) {
        self.requestTimeout = requestTimeout
        self.maxResponseBytes = maxResponseBytes
        self.autoRestart = autoRestart
        self.maxRestarts = maxRestarts
    }

    public static let `default` = RemoteExtensionHostPolicy()
}
