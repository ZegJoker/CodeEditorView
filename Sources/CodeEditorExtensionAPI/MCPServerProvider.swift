import Foundation

public enum MCPTransportKind: String, Sendable, Hashable, Codable {
    case stdio
}

public enum MCPBinarySource: Sendable, Hashable, Codable {
    case systemPath(name: String)
    case worktreeRelative(path: String)
    case downloaded(url: String, digest: String?, cacheKey: String)
    case npm(package: String, version: String?, bin: String)
    case absolute(path: String)
    case testFactory(id: String)
}

public struct SecretReference: Sendable, Hashable, Codable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct MCPServerLaunchPlan: Sendable, Hashable, Codable {
    public var serverID: String
    public var displayName: String
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var secretEnvironment: [String: SecretReference]
    public var workingDirectoryRelative: String?
    public var transport: MCPTransportKind
    public var binarySource: MCPBinarySource
    public var startupTimeoutMS: Int
    public var extensionID: ExtensionID?

    public init(
        serverID: String,
        displayName: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        secretEnvironment: [String: SecretReference] = [:],
        workingDirectoryRelative: String? = nil,
        transport: MCPTransportKind = .stdio,
        binarySource: MCPBinarySource,
        startupTimeoutMS: Int = 10_000,
        extensionID: ExtensionID? = nil
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.secretEnvironment = secretEnvironment
        self.workingDirectoryRelative = workingDirectoryRelative
        self.transport = transport
        self.binarySource = binarySource
        self.startupTimeoutMS = startupTimeoutMS
        self.extensionID = extensionID
    }
}

public struct MCPServerContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String { serverID }
    public var serverID: String
    public var displayName: String
    public var command: String?
    public var arguments: [String]
    public var transport: MCPTransportKind
    public var startupTimeoutMS: Int
    public var downloadURL: String?
    public var downloadDigest: String?
    public var npmPackage: String?
    public var npmVersion: String?
    public var npmBin: String?
    public var extensionID: ExtensionID?

    public init(
        serverID: String,
        displayName: String? = nil,
        command: String? = nil,
        arguments: [String] = [],
        transport: MCPTransportKind = .stdio,
        startupTimeoutMS: Int = 10_000,
        downloadURL: String? = nil,
        downloadDigest: String? = nil,
        npmPackage: String? = nil,
        npmVersion: String? = nil,
        npmBin: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.serverID = serverID
        self.displayName = displayName ?? serverID
        self.command = command
        self.arguments = arguments
        self.transport = transport
        self.startupTimeoutMS = startupTimeoutMS
        self.downloadURL = downloadURL
        self.downloadDigest = downloadDigest
        self.npmPackage = npmPackage
        self.npmVersion = npmVersion
        self.npmBin = npmBin
        self.extensionID = extensionID
    }

    public func makeSeedPlan() -> MCPServerLaunchPlan {
        let source: MCPBinarySource
        if let npmPackage {
            source = .npm(package: npmPackage, version: npmVersion, bin: npmBin ?? command ?? npmPackage)
        } else if let downloadURL {
            source = .downloaded(url: downloadURL, digest: downloadDigest, cacheKey: serverID)
        } else if let command, command.contains("/") {
            source = command.hasPrefix("/") ? .absolute(path: command) : .worktreeRelative(path: command)
        } else {
            source = .systemPath(name: command ?? serverID)
        }
        return MCPServerLaunchPlan(
            serverID: serverID,
            displayName: displayName,
            command: command ?? serverID,
            arguments: arguments,
            transport: transport,
            binarySource: source,
            startupTimeoutMS: startupTimeoutMS,
            extensionID: extensionID
        )
    }
}

public protocol MCPServerProvider: Sendable {
    var serverIDs: [String] { get }
    func resolveLaunchPlan(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> MCPServerLaunchPlan
}

public enum MCPLifecycleState: String, Sendable, Hashable, Codable {
    case idle, resolving, starting, running, failed, stopped
}

public struct MCPServerStatus: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(extensionID.rawValue)::\(serverID)" }
    public var serverID: String
    public var extensionID: ExtensionID
    public var state: MCPLifecycleState
    public var message: String?
    public var lastError: String?
    public var updatedAt: Date

    public init(
        serverID: String,
        extensionID: ExtensionID,
        state: MCPLifecycleState,
        message: String? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.serverID = serverID
        self.extensionID = extensionID
        self.state = state
        self.message = message
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public enum MCPProviderError: Error, Sendable, Equatable {
    case unknownServer(String)
    case resolutionFailed(String)
}
