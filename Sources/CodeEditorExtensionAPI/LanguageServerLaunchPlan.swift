import Foundation

/// How the language-server process is transported (host-owned connection).
public enum LanguageServerTransportKind: String, Sendable, Hashable, Codable {
    case stdio
}

/// Where the server binary comes from (host materializes; extension only describes).
public enum LanguageServerBinarySource: Sendable, Hashable, Codable {
    case systemPath(name: String)
    case worktreeRelative(path: String)
    case downloaded(url: String, digest: String?, cacheKey: String)
    case npm(package: String, version: String?, bin: String)
    /// Tests / elevated grants only.
    case absolute(path: String)
    /// In-process test factory registered on ``LanguageServerPool``.
    case testFactory(id: String)

    public var kindName: String {
        switch self {
        case .systemPath: return "systemPath"
        case .worktreeRelative: return "worktreeRelative"
        case .downloaded: return "downloaded"
        case .npm: return "npm"
        case .absolute: return "absolute"
        case .testFactory: return "testFactory"
        }
    }
}

/// Declarative / resolved launch plan returned by extensions (host executes).
public struct LanguageServerLaunchPlan: Sendable, Hashable, Codable {
    public var serverID: String
    public var displayName: String
    public var languages: [String]
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryRelative: String?
    public var transport: LanguageServerTransportKind
    public var initializationOptionsJSON: Data?
    public var binarySource: LanguageServerBinarySource
    public var extensionID: ExtensionID?

    public init(
        serverID: String,
        displayName: String,
        languages: [String] = [],
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryRelative: String? = nil,
        transport: LanguageServerTransportKind = .stdio,
        initializationOptionsJSON: Data? = nil,
        binarySource: LanguageServerBinarySource,
        extensionID: ExtensionID? = nil
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.languages = languages
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryRelative = workingDirectoryRelative
        self.transport = transport
        self.initializationOptionsJSON = initializationOptionsJSON
        self.binarySource = binarySource
        self.extensionID = extensionID
    }
}

/// Static contribution from `extension.toml` `[language_servers.*]`.
public struct LanguageServerContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String { serverID }
    public var serverID: String
    public var displayName: String
    public var languages: [String]
    public var command: String?
    public var arguments: [String]
    public var downloadURL: String?
    public var downloadDigest: String?
    public var npmPackage: String?
    public var npmVersion: String?
    public var npmBin: String?
    public var extensionID: ExtensionID?

    public init(
        serverID: String,
        displayName: String? = nil,
        languages: [String] = [],
        command: String? = nil,
        arguments: [String] = [],
        downloadURL: String? = nil,
        downloadDigest: String? = nil,
        npmPackage: String? = nil,
        npmVersion: String? = nil,
        npmBin: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.serverID = serverID
        self.displayName = displayName ?? serverID
        self.languages = languages
        self.command = command
        self.arguments = arguments
        self.downloadURL = downloadURL
        self.downloadDigest = downloadDigest
        self.npmPackage = npmPackage
        self.npmVersion = npmVersion
        self.npmBin = npmBin
        self.extensionID = extensionID
    }

    /// Seed plan from static TOML (no PATH resolution yet).
    public func makeSeedPlan() -> LanguageServerLaunchPlan {
        let source: LanguageServerBinarySource
        if let npmPackage {
            source = .npm(package: npmPackage, version: npmVersion, bin: npmBin ?? command ?? npmPackage)
        } else if let downloadURL {
            source = .downloaded(url: downloadURL, digest: downloadDigest, cacheKey: serverID)
        } else if let command, command.contains("/") {
            source = command.hasPrefix("/") ? .absolute(path: command) : .worktreeRelative(path: command)
        } else {
            source = .systemPath(name: command ?? serverID)
        }
        return LanguageServerLaunchPlan(
            serverID: serverID,
            displayName: displayName,
            languages: languages,
            command: command ?? serverID,
            arguments: arguments,
            binarySource: source,
            extensionID: extensionID
        )
    }
}
