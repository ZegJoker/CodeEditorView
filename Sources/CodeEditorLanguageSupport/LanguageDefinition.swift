import Foundation

/// Host-facing language metadata (no parser or query implementation).
public struct LanguageDefinition: Hashable, Sendable, Identifiable {
    public var id: LanguageID
    public var displayName: String
    /// tree-sitter resource directory name (`tree-sitter-{tsName}`).
    public var tsName: String
    public var fileExtensions: Set<String>
    public var aliases: Set<String>
    public var lineComment: String
    public var blockComment: (String, String)
    /// Additional query basenames to merge (e.g. `"folds"`, `"locals"`). `highlights` is always loaded.
    public var additionalQueries: Set<String>
    /// Optional parent language whose `highlights.scm` is prepended (e.g. C for C++).
    public var parent: LanguageID?

    public init(
        id: LanguageID,
        displayName: String,
        tsName: String,
        fileExtensions: Set<String> = [],
        aliases: Set<String> = [],
        lineComment: String = "",
        blockComment: (String, String) = ("", ""),
        additionalQueries: Set<String> = [],
        parent: LanguageID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tsName = tsName
        self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
        self.aliases = Set(aliases.map { $0.lowercased() })
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.additionalQueries = additionalQueries
        self.parent = parent
    }

    public static func == (lhs: LanguageDefinition, rhs: LanguageDefinition) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension LanguageDefinition {
    /// Builds a definition from a catalog ``CodeLanguage``.
    public init(_ language: CodeLanguage) {
        self.init(
            id: language.languageID,
            displayName: language.displayName,
            tsName: language.tsName,
            fileExtensions: language.extensions,
            aliases: language.aliases,
            lineComment: language.lineComment,
            blockComment: language.rangeComment,
            additionalQueries: language.additionalQueries,
            parent: language.parent.map { LanguageID(rawValue: $0.rawValue) }
        )
    }
}
