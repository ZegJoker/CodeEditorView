import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices

public struct LanguageServerID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum LanguageServerLaunch: Sendable {
    case process(executable: URL, arguments: [String])
    /// In-process mock registered with ``LanguageServerPool/registerTestFactory``.
    case test(factoryID: String)
    case custom(@Sendable () async throws -> any LSPTransport)
}

public struct LanguageServerDefinition: Sendable {
    public var id: LanguageServerID
    public var displayName: String
    public var languages: Set<String>
    public var documentSelector: DocumentSelector
    public var launch: LanguageServerLaunch
    public var workspaceRootURIs: [DocumentURI]
    public var environment: [String: String]
    public var currentDirectory: URL?
    /// Raw JSON object for `initializationOptions` (Sendable wrapper).
    public var initializationOptions: LSPJSONObject?

    public init(
        id: LanguageServerID,
        displayName: String,
        languages: Set<String> = [],
        documentSelector: DocumentSelector = .any,
        launch: LanguageServerLaunch,
        workspaceRootURIs: [DocumentURI] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        initializationOptions: LSPJSONObject? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.languages = Set(languages.map { $0.lowercased() })
        self.documentSelector = documentSelector
        self.launch = launch
        self.workspaceRootURIs = workspaceRootURIs
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.initializationOptions = initializationOptions
    }

    /// Pool identity key: server id + sorted workspace roots (not executable path alone).
    public var poolKey: String {
        let roots = workspaceRootURIs.map(\.rawValue).sorted().joined(separator: "|")
        return "\(id.rawValue)::\(roots)"
    }
}

public enum LanguageServerState: String, Sendable, Hashable, Codable {
    case idle
    case starting
    case running
    case shuttingDown
    case stopped
    case failed
}

/// Tracked open document snapshot for resync after restart.
public struct LSPOpenDocumentState: Sendable, Hashable {
    public var uri: DocumentURI
    public var languageID: String
    public var version: DocumentVersion
    public var text: String

    public init(uri: DocumentURI, languageID: String, version: DocumentVersion, text: String) {
        self.uri = uri
        self.languageID = languageID
        self.version = version
        self.text = text
    }
}

public struct LSPContentChange: Sendable, Hashable {
    /// When nil, full document replace (LSP full change).
    public var range: CodeEditorCore.TextRange?
    public var text: String

    public init(range: CodeEditorCore.TextRange? = nil, text: String) {
        self.range = range
        self.text = text
    }
}
