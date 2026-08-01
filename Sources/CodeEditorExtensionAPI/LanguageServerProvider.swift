import Foundation

/// Opaque handle ids (host maps to broker handles).
public struct WorktreeHandleID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProjectHandleID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SettingsHandleID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct StorageHandleID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ExtensionPlatformInfo: Sendable, Hashable, Codable {
    public var os: String
    public var arch: String
    public var isSimulator: Bool
    public var profileName: String
    public var processLaunchAllowed: Bool

    public init(
        os: String,
        arch: String,
        isSimulator: Bool = false,
        profileName: String = "default",
        processLaunchAllowed: Bool = true
    ) {
        self.os = os
        self.arch = arch
        self.isSimulator = isSimulator
        self.profileName = profileName
        self.processLaunchAllowed = processLaunchAllowed
    }

    public static var current: ExtensionPlatformInfo {
        #if os(macOS)
            let os = "macOS"
        #elseif os(iOS)
            let os = "iOS"
        #else
            let os = "unknown"
        #endif
        #if targetEnvironment(simulator)
            let sim = true
        #else
            let sim = false
        #endif
        #if arch(arm64)
            let arch = "arm64"
        #elseif arch(x86_64)
            let arch = "x86_64"
        #else
            let arch = "unknown"
        #endif
        return ExtensionPlatformInfo(os: os, arch: arch, isSimulator: sim)
    }
}

/// Result of scoped worktree executable lookup (host-filled; extension never sees raw PATH).
public struct WorktreeExecutableLocation: Sendable, Hashable, Codable {
    public var name: String
    public var absolutePath: String

    public init(name: String, absolutePath: String) {
        self.name = name
        self.absolutePath = absolutePath
    }
}

/// Snapshot of project/worktree metadata available during LS resolve.
public struct ProjectMetadataSnapshot: Sendable, Hashable, Codable {
    public var name: String
    public var rootPaths: [String]

    public init(name: String = "project", rootPaths: [String] = []) {
        self.name = name
        self.rootPaths = rootPaths
    }
}

public struct LanguageServerResolveContext: Sendable {
    public var platform: ExtensionPlatformInfo
    public var extensionID: ExtensionID
    public var worktree: WorktreeHandleID?
    public var project: ProjectHandleID?
    public var settings: SettingsHandleID?
    public var storage: StorageHandleID?
    /// Host-provided settings snapshot (JSON-compatible string map).
    public var settingsValues: [String: String]
    public var workspaceRootPaths: [String]
    /// Allowed worktree environment variables (host-filtered allowlist).
    public var environmentValues: [String: String]
    /// Pre-resolved executables from scoped worktree PATH (name → absolute path).
    public var whichResults: [String: String]
    public var projectMetadata: ProjectMetadataSnapshot

    public init(
        platform: ExtensionPlatformInfo = .current,
        extensionID: ExtensionID,
        worktree: WorktreeHandleID? = nil,
        project: ProjectHandleID? = nil,
        settings: SettingsHandleID? = nil,
        storage: StorageHandleID? = nil,
        settingsValues: [String: String] = [:],
        workspaceRootPaths: [String] = [],
        environmentValues: [String: String] = [:],
        whichResults: [String: String] = [:],
        projectMetadata: ProjectMetadataSnapshot = ProjectMetadataSnapshot()
    ) {
        self.platform = platform
        self.extensionID = extensionID
        self.worktree = worktree
        self.project = project
        self.settings = settings
        self.storage = storage
        self.settingsValues = settingsValues
        self.workspaceRootPaths = workspaceRootPaths
        self.environmentValues = environmentValues
        self.whichResults = whichResults
        self.projectMetadata = projectMetadata
    }

    /// Convenience: absolute path for an executable found via host `which`.
    public func which(_ name: String) -> String? {
        whichResults[name]
    }
}

/// Per-language preferred language-server IDs (extension contribution + runtime map).
public struct LanguageServerLanguageMap: Sendable, Hashable, Codable {
    /// language ID (lowercased) → ordered server IDs
    public var serversByLanguage: [String: [String]]

    public init(serversByLanguage: [String: [String]] = [:]) {
        self.serversByLanguage = serversByLanguage
    }

    public mutating func register(serverID: String, languages: [String]) {
        for lang in languages {
            let key = lang.lowercased()
            var list = serversByLanguage[key] ?? []
            if !list.contains(serverID) {
                list.append(serverID)
            }
            serversByLanguage[key] = list
        }
    }

    public func servers(forLanguage languageID: String) -> [String] {
        serversByLanguage[languageID.lowercased()] ?? []
    }

    public static func fromContributions(_ contributions: [LanguageServerContribution]) -> LanguageServerLanguageMap {
        var map = LanguageServerLanguageMap()
        for c in contributions {
            map.register(serverID: c.serverID, languages: c.languages)
        }
        return map
    }
}

public struct WorkspaceConfigurationItem: Sendable, Hashable, Codable {
    public var section: String?
    public var scopeURI: String?

    public init(section: String? = nil, scopeURI: String? = nil) {
        self.section = section
        self.scopeURI = scopeURI
    }
}

public struct CompletionLabelTransform: Sendable, Hashable, Codable {
    public var label: String
    public var detail: String?
    public var insertText: String?
    public var filterText: String?

    public init(label: String, detail: String? = nil, insertText: String? = nil, filterText: String? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.filterText = filterText
    }
}

public struct SymbolLabelTransform: Sendable, Hashable, Codable {
    public var name: String
    public var detail: String?
    public var containerName: String?

    public init(name: String, detail: String? = nil, containerName: String? = nil) {
        self.name = name
        self.detail = detail
        self.containerName = containerName
    }
}

/// Procedural language-server hooks (§8.5). Host owns process + LSP socket.
public protocol LanguageServerProvider: Sendable {
    var serverIDs: [String] { get }

    func resolveLaunchPlan(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> LanguageServerLaunchPlan

    func initializationOptions(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> Data?

    func workspaceConfiguration(
        serverID: String,
        items: [WorkspaceConfigurationItem]
    ) async throws -> [Data?]

    func transformCompletionLabel(_ item: CompletionLabelTransform) async -> CompletionLabelTransform
    func transformSymbolLabel(_ item: SymbolLabelTransform) async -> SymbolLabelTransform
}

extension LanguageServerProvider {
    public func initializationOptions(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> Data? {
        nil
    }

    public func workspaceConfiguration(
        serverID: String,
        items: [WorkspaceConfigurationItem]
    ) async throws -> [Data?] {
        items.map { _ in nil }
    }

    public func transformCompletionLabel(_ item: CompletionLabelTransform) async -> CompletionLabelTransform {
        item
    }

    public func transformSymbolLabel(_ item: SymbolLabelTransform) async -> SymbolLabelTransform {
        item
    }
}

public enum LanguageServerProviderError: Error, Sendable, Equatable {
    case unknownServer(String)
    case notSupported(String)
    case resolutionFailed(String)
}
