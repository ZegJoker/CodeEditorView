import Foundation

/// Metadata for a programming language and its tree-sitter resources.
///
/// Query files and parsers are registered by language packs (or the
/// ``CodeEditorLanguages`` umbrella) into ``LanguageRegistry``. This type holds
/// catalog metadata only — it does not import grammar C targets.
public struct CodeLanguage: Hashable, Sendable, Identifiable {
    public var id: TreeSitterLanguageID
    /// tree-sitter resource directory name (`tree-sitter-{tsName}`).
    public var tsName: String
    public var displayName: String
    public var extensions: Set<String>
    public var lineComment: String
    public var rangeComment: (String, String)
    /// Additional query basenames to merge (e.g. `"folds"`, `"locals"`). `highlights` is always loaded.
    public var additionalQueries: Set<String>
    /// Optional parent language whose `highlights.scm` is prepended (e.g. C for C++).
    public var parent: TreeSitterLanguageID?
    public var aliases: Set<String>

    public init(
        id: TreeSitterLanguageID,
        tsName: String,
        displayName: String,
        extensions: Set<String>,
        lineComment: String = "",
        rangeComment: (String, String) = ("", ""),
        additionalQueries: Set<String> = [],
        parent: TreeSitterLanguageID? = nil,
        aliases: Set<String> = []
    ) {
        self.id = id
        self.tsName = tsName
        self.displayName = displayName
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.lineComment = lineComment
        self.rangeComment = rangeComment
        self.additionalQueries = additionalQueries
        self.parent = parent
        self.aliases = Set(aliases.map { $0.lowercased() })
    }

    /// Open language identifier for registry / pack APIs.
    public var languageID: LanguageID {
        id.languageID
    }

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Queries

    /// URL for a query file: `tree-sitter-{tsName}/{name}.scm`
    ///
    /// Resolved via ``LanguageRegistry`` query providers registered by language packs.
    public func queryURL(for name: String = "highlights") -> URL? {
        LanguageRegistry.shared.queryURL(for: languageID, query: name)
    }
}
