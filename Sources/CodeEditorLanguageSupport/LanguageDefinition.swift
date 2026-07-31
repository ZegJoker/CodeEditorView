import Foundation

/// Host-facing language metadata (no parser or query implementation).
public struct LanguageDefinition: Hashable, Sendable, Identifiable {
    public var id: LanguageID
    public var displayName: String
    /// tree-sitter resource directory name (`tree-sitter-{tsName}`).
    public var tsName: String
    public var fileExtensions: Set<String>
    public var aliases: Set<String>
    /// Exact filenames that map to this language (e.g. `Package.swift`, `Dockerfile`).
    public var filenames: Set<String>
    /// First-line regex patterns (shebang / modeline style), matched against the first line only.
    public var firstLinePatterns: [String]
    /// Content regex patterns applied to a bounded prefix of the file.
    public var contentPatterns: [String]
    /// Higher wins on ambiguous extension collisions.
    public var detectionPriority: Int
    public var lineComment: String
    public var blockComment: (String, String)
    public var tabSize: Int
    public var insertSpaces: Bool
    /// Character class / regex for word characters (editor selection); empty = default.
    public var wordPattern: String
    /// Bracket pairs for matching (open, close).
    public var brackets: [(String, String)]
    /// Additional query basenames to merge (e.g. `"folds"`, `"locals"`). `highlights` is always loaded.
    public var additionalQueries: Set<String>
    /// Typed query kinds this language expects (defaults derived from additionalQueries + highlights).
    public var queryKinds: Set<QueryKind>
    /// Optional parent language whose `highlights.scm` is prepended (e.g. C for C++).
    public var parent: LanguageID?
    /// Placeholder IDs for host-configured tooling order.
    public var preferredLanguageServers: [String]
    public var preferredFormatters: [String]
    public var preferredDebuggers: [String]
    /// Whether comments are allowed (JSONC vs strict JSON).
    public var allowsComments: Bool

    public init(
        id: LanguageID,
        displayName: String,
        tsName: String,
        fileExtensions: Set<String> = [],
        aliases: Set<String> = [],
        filenames: Set<String> = [],
        firstLinePatterns: [String] = [],
        contentPatterns: [String] = [],
        detectionPriority: Int = 0,
        lineComment: String = "",
        blockComment: (String, String) = ("", ""),
        tabSize: Int = 4,
        insertSpaces: Bool = true,
        wordPattern: String = "",
        brackets: [(String, String)] = [("(", ")"), ("[", "]"), ("{", "}")],
        additionalQueries: Set<String> = [],
        queryKinds: Set<QueryKind>? = nil,
        parent: LanguageID? = nil,
        preferredLanguageServers: [String] = [],
        preferredFormatters: [String] = [],
        preferredDebuggers: [String] = [],
        allowsComments: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.tsName = tsName
        self.fileExtensions = Set(fileExtensions.map { $0.lowercased() })
        self.aliases = Set(aliases.map { $0.lowercased() })
        self.filenames = Set(filenames.map { $0.lowercased() })
        self.firstLinePatterns = firstLinePatterns
        self.contentPatterns = contentPatterns
        self.detectionPriority = detectionPriority
        self.lineComment = lineComment
        self.blockComment = blockComment
        self.tabSize = max(1, tabSize)
        self.insertSpaces = insertSpaces
        self.wordPattern = wordPattern
        self.brackets = brackets
        self.additionalQueries = additionalQueries
        if let queryKinds {
            self.queryKinds = queryKinds
        } else {
            var kinds: Set<QueryKind> = [.highlights]
            for name in additionalQueries {
                if let kind = QueryKind(rawValue: name) {
                    kinds.insert(kind)
                }
            }
            self.queryKinds = kinds
        }
        self.parent = parent
        self.preferredLanguageServers = preferredLanguageServers
        self.preferredFormatters = preferredFormatters
        self.preferredDebuggers = preferredDebuggers
        self.allowsComments = allowsComments
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
        var filenames: Set<String> = []
        var firstLine: [String] = []
        var priority = 0
        var allowsComments = true
        switch language.id {
        case .swift:
            filenames = ["package.swift"]
            priority = 10
        case .json:
            allowsComments = false
            priority = 5
        case .dockerfile:
            filenames = ["dockerfile"]
            firstLine = [#"^#!.*\bdocker\b"#]
        case .ruby:
            firstLine = [#"^#!.*\bruby\b"#]
        case .python:
            firstLine = [#"^#!.*\bpython"#]
        case .bash:
            firstLine = [#"^#!.*\b(ba|z|k|a)?sh\b"#]
            filenames = [".bashrc", ".zshrc", ".profile"]
        default:
            break
        }
        self.init(
            id: language.languageID,
            displayName: language.displayName,
            tsName: language.tsName,
            fileExtensions: language.extensions,
            aliases: language.aliases,
            filenames: filenames,
            firstLinePatterns: firstLine,
            detectionPriority: priority,
            lineComment: language.lineComment,
            blockComment: language.rangeComment,
            additionalQueries: language.additionalQueries,
            parent: language.parent.map { LanguageID(rawValue: $0.rawValue) },
            allowsComments: allowsComments
        )
    }
}
