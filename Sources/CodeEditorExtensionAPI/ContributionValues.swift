import CodeEditorLanguageSupport
import Foundation

public struct PanelContribution: Sendable, Hashable, Identifiable {
    public var id: String
    public var slot: String
    public var title: String
    public var priority: Int
    public var extensionID: ExtensionID

    public init(
        id: String,
        slot: String,
        title: String,
        priority: Int = 0,
        extensionID: ExtensionID
    ) {
        self.id = id
        self.slot = slot
        self.title = title
        self.priority = priority
        self.extensionID = extensionID
    }
}

public struct ThemeContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var tokens: [String: String]
    public var extensionID: ExtensionID?

    public init(
        id: String,
        displayName: String,
        tokens: [String: String] = [:],
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tokens = tokens
        self.extensionID = extensionID
    }
}

public struct SnippetContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var prefix: String
    public var body: String
    public var languageID: String?
    public var description: String?
    public var extensionID: ExtensionID?

    public init(
        id: String,
        prefix: String,
        body: String,
        languageID: String? = nil,
        description: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.prefix = prefix
        self.body = body
        self.languageID = languageID
        self.description = description
        self.extensionID = extensionID
    }
}

public struct IconThemeContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    /// File extension or language id → icon asset path relative to package.
    public var fileIcons: [String: String]
    public var folderIcons: [String: String]
    public var extensionID: ExtensionID?

    public init(
        id: String,
        displayName: String,
        fileIcons: [String: String] = [:],
        folderIcons: [String: String] = [:],
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileIcons = fileIcons
        self.folderIcons = folderIcons
        self.extensionID = extensionID
    }
}

public struct LanguageDefinitionDTO: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    public var tsName: String
    public var fileExtensions: [String]
    public var aliases: [String]
    public var lineComment: String
    public var blockCommentStart: String
    public var blockCommentEnd: String
    /// Optional path to language config.toml relative to package (TOML packages).
    public var configPath: String?
    public var highlightsQuery: String?

    public init(
        id: String,
        displayName: String,
        tsName: String = "",
        fileExtensions: [String] = [],
        aliases: [String] = [],
        lineComment: String = "",
        blockCommentStart: String = "",
        blockCommentEnd: String = "",
        configPath: String? = nil,
        highlightsQuery: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tsName = tsName.isEmpty ? id : tsName
        self.fileExtensions = fileExtensions
        self.aliases = aliases
        self.lineComment = lineComment
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
        self.configPath = configPath
        self.highlightsQuery = highlightsQuery
    }
}

public struct KeybindingOverrideDTO: Sendable, Hashable, Codable {
    public var commandID: String
    public var key: String
    public var modifiers: [String]
    public var priority: Int

    public init(
        commandID: String,
        key: String,
        modifiers: [String] = [],
        priority: Int = 0
    ) {
        self.commandID = commandID
        self.key = key
        self.modifiers = modifiers
        self.priority = priority
    }
}

public struct AssetContribution: Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var absoluteURL: URL?

    public init(relativePath: String, absoluteURL: URL? = nil) {
        self.relativePath = relativePath
        self.absoluteURL = absoluteURL
    }
}

/// Grammar declaration (source path / optional prebuilt binary). S1 data-only.
public struct GrammarContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var languageID: String
    public var grammarPath: String?
    public var repository: String?
    public var commit: String?
    public var extensionID: ExtensionID?

    public init(
        id: String,
        languageID: String,
        grammarPath: String? = nil,
        repository: String? = nil,
        commit: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.languageID = languageID
        self.grammarPath = grammarPath
        self.repository = repository
        self.commit = commit
        self.extensionID = extensionID
    }
}

/// Tree-sitter query file contribution (highlights, indents, …).
public struct QueryContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(languageID):\(kind)" }
    public var languageID: String
    public var kind: String
    public var relativePath: String
    public var extensionID: ExtensionID?

    public init(
        languageID: String,
        kind: String,
        relativePath: String,
        extensionID: ExtensionID? = nil
    ) {
        self.languageID = languageID
        self.kind = kind
        self.relativePath = relativePath
        self.extensionID = extensionID
    }
}
