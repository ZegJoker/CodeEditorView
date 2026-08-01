import Foundation

// MARK: - Launch plan

public enum DebugAdapterTransportKind: String, Sendable, Hashable, Codable {
    case stdio
    case tcp
    case listenPort
}

public enum DebugAdapterBinarySource: Sendable, Hashable, Codable {
    case systemPath(name: String)
    case worktreeRelative(path: String)
    case downloaded(url: String, digest: String?, cacheKey: String)
    case npm(package: String, version: String?, bin: String)
    case absolute(path: String)
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

public struct DebugAdapterLaunchPlan: Sendable, Hashable, Codable {
    public var adapterID: String
    public var displayName: String
    public var languages: [String]
    public var command: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectoryRelative: String?
    public var transport: DebugAdapterTransportKind
    public var tcpHost: String?
    public var tcpPort: Int?
    public var binarySource: DebugAdapterBinarySource
    public var extensionID: ExtensionID?
    public var preDebugTaskID: String?
    public var postDebugTaskID: String?

    public init(
        adapterID: String,
        displayName: String,
        languages: [String] = [],
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryRelative: String? = nil,
        transport: DebugAdapterTransportKind = .stdio,
        tcpHost: String? = nil,
        tcpPort: Int? = nil,
        binarySource: DebugAdapterBinarySource,
        extensionID: ExtensionID? = nil,
        preDebugTaskID: String? = nil,
        postDebugTaskID: String? = nil
    ) {
        self.adapterID = adapterID
        self.displayName = displayName
        self.languages = languages
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryRelative = workingDirectoryRelative
        self.transport = transport
        self.tcpHost = tcpHost
        self.tcpPort = tcpPort
        self.binarySource = binarySource
        self.extensionID = extensionID
        self.preDebugTaskID = preDebugTaskID
        self.postDebugTaskID = postDebugTaskID
    }
}

public struct DebugAdapterContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String { adapterID }
    public var adapterID: String
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
        adapterID: String,
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
        self.adapterID = adapterID
        self.displayName = displayName ?? adapterID
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

    public func makeSeedPlan() -> DebugAdapterLaunchPlan {
        let source: DebugAdapterBinarySource
        if let npmPackage {
            source = .npm(package: npmPackage, version: npmVersion, bin: npmBin ?? command ?? npmPackage)
        } else if let downloadURL {
            source = .downloaded(url: downloadURL, digest: downloadDigest, cacheKey: adapterID)
        } else if let command, command.contains("/") {
            source = command.hasPrefix("/") ? .absolute(path: command) : .worktreeRelative(path: command)
        } else {
            source = .systemPath(name: command ?? adapterID)
        }
        return DebugAdapterLaunchPlan(
            adapterID: adapterID,
            displayName: displayName,
            languages: languages,
            command: command ?? adapterID,
            arguments: arguments,
            binarySource: source,
            extensionID: extensionID
        )
    }
}

public enum DebugConfigurationRequest: String, Sendable, Hashable, Codable {
    case launch
    case attach
}

public struct DebugConfiguration: Sendable, Hashable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var request: DebugConfigurationRequest
    /// Bounded JSON object for adapter-specific fields.
    public var bodyJSON: Data?

    public init(
        name: String,
        type: String,
        request: DebugConfigurationRequest = .launch,
        bodyJSON: Data? = nil
    ) {
        self.name = name
        self.type = type
        self.request = request
        self.bodyJSON = bodyJSON
    }
}

public enum DebugRequestClassification: String, Sendable, Hashable, Codable {
    case launch
    case attach
    case custom
}

public struct VariablePresentationHint: Sendable, Hashable, Codable {
    public var kind: String?
    public var attributes: [String]
    public var visibility: String?

    public init(kind: String? = nil, attributes: [String] = [], visibility: String? = nil) {
        self.kind = kind
        self.attributes = attributes
        self.visibility = visibility
    }
}

public struct DebugLocatorContext: Sendable {
    public var extensionID: ExtensionID
    public var uri: String?
    public var languageID: String?
    public var workspaceRootPaths: [String]

    public init(
        extensionID: ExtensionID,
        uri: String? = nil,
        languageID: String? = nil,
        workspaceRootPaths: [String] = []
    ) {
        self.extensionID = extensionID
        self.uri = uri
        self.languageID = languageID
        self.workspaceRootPaths = workspaceRootPaths
    }
}

public struct DebugLocatorMatch: Sendable, Hashable, Codable {
    public var adapterID: String
    public var configuration: DebugConfiguration
    public var confidence: Double

    public init(adapterID: String, configuration: DebugConfiguration, confidence: Double = 1.0) {
        self.adapterID = adapterID
        self.configuration = configuration
        self.confidence = confidence
    }
}

public protocol DebugAdapterProvider: Sendable {
    var adapterIDs: [String] { get }
    func resolveLaunchPlan(
        adapterID: String,
        context: LanguageServerResolveContext
    ) async throws -> DebugAdapterLaunchPlan
    func resolveConfigurations(
        adapterID: String,
        context: LanguageServerResolveContext
    ) async throws -> [DebugConfiguration]
    func requestClassification(adapterID: String, command: String) async -> DebugRequestClassification?
    func transformVariablePresentation(
        name: String,
        value: String,
        type: String?
    ) async -> VariablePresentationHint?
}

public extension DebugAdapterProvider {
    func resolveConfigurations(
        adapterID: String,
        context: LanguageServerResolveContext
    ) async throws -> [DebugConfiguration] { [] }

    func requestClassification(adapterID: String, command: String) async -> DebugRequestClassification? {
        nil
    }

    func transformVariablePresentation(
        name: String,
        value: String,
        type: String?
    ) async -> VariablePresentationHint? { nil }
}

public protocol DebugLocatorProvider: Sendable {
    func locate(context: DebugLocatorContext) async throws -> [DebugLocatorMatch]
}

public enum DebugAdapterLifecycleState: String, Sendable, Hashable, Codable {
    case idle, resolving, installing, starting, running, failed, stopped
}

public struct DebugAdapterStatus: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(extensionID.rawValue)::\(adapterID)" }
    public var adapterID: String
    public var extensionID: ExtensionID
    public var state: DebugAdapterLifecycleState
    public var message: String?
    public var lastError: String?
    public var binaryPath: String?
    public var updatedAt: Date

    public init(
        adapterID: String,
        extensionID: ExtensionID,
        state: DebugAdapterLifecycleState,
        message: String? = nil,
        lastError: String? = nil,
        binaryPath: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.adapterID = adapterID
        self.extensionID = extensionID
        self.state = state
        self.message = message
        self.lastError = lastError
        self.binaryPath = binaryPath
        self.updatedAt = updatedAt
    }
}

public enum DebugAdapterDiagnosticCode: String, Sendable, Hashable, Codable {
    case binaryNotFound = "dap.binary_not_found"
    case downloadDenied = "dap.download_denied"
    case processDenied = "dap.process_denied"
    case pathEscape = "dap.path_escape"
    case planInvalid = "dap.plan_invalid"
    case spawnFailed = "dap.spawn_failed"
}

public struct DebugAdapterDiagnostic: Sendable, Hashable, Codable {
    public var code: DebugAdapterDiagnosticCode
    public var message: String
    public var adapterID: String?
    public var extensionID: ExtensionID?

    public init(
        code: DebugAdapterDiagnosticCode,
        message: String,
        adapterID: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.code = code
        self.message = message
        self.adapterID = adapterID
        self.extensionID = extensionID
    }
}

public enum DebugAdapterProviderError: Error, Sendable, Equatable {
    case unknownAdapter(String)
    case notSupported(String)
    case resolutionFailed(String)
}
