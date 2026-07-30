import Foundation
import CodeEditorCore
import CodeEditorDocuments

public struct SearchQuery: Sendable, Hashable {
    public var pattern: String
    public var isRegex: Bool
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxFileBytes: Int
    public var maxResults: Int

    public init(
        pattern: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = SearchQuery.defaultExcludes,
        maxFileBytes: Int = 1_000_000,
        maxResults: Int = 10_000
    ) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxFileBytes = maxFileBytes
        self.maxResults = maxResults
    }

    public static let defaultExcludes: [String] = [
        "**/.git/**",
        "**/.build/**",
        "**/DerivedData/**",
        "**/node_modules/**",
        "**/.swiftpm/**",
    ]
}

public struct SearchMatch: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var uri: DocumentURI
    public var range: CodeEditorCore.TextRange
    public var line: Int
    public var column: Int
    public var preview: String
    public var fromOpenDocument: Bool

    public init(
        id: UUID = UUID(),
        uri: DocumentURI,
        range: CodeEditorCore.TextRange,
        line: Int,
        column: Int,
        preview: String,
        fromOpenDocument: Bool
    ) {
        self.id = id
        self.uri = uri
        self.range = range
        self.line = line
        self.column = column
        self.preview = preview
        self.fromOpenDocument = fromOpenDocument
    }
}

public struct SearchProgress: Sendable, Hashable {
    public var filesScanned: Int
    public var matchesFound: Int
    public var currentPath: String?

    public init(filesScanned: Int, matchesFound: Int, currentPath: String? = nil) {
        self.filesScanned = filesScanned
        self.matchesFound = matchesFound
        self.currentPath = currentPath
    }
}

public enum SearchEvent: Sendable {
    case progress(SearchProgress)
    case match(SearchMatch)
    case finished(filesScanned: Int, matchCount: Int)
}

public enum SearchError: Error, Sendable, Equatable {
    case emptyPattern
    case invalidRegex(String)
    case cancelled
}

/// Sendable snapshot for searching without holding MainActor Workspace.
public struct WorkspaceSearchContext: Sendable {
    public var rootDirectories: [URL]
    public var openDocuments: [DocumentURI: String]
    public var openDocumentVersions: [DocumentURI: DocumentVersion]

    public init(
        rootDirectories: [URL] = [],
        openDocuments: [DocumentURI: String] = [:],
        openDocumentVersions: [DocumentURI: DocumentVersion] = [:]
    ) {
        self.rootDirectories = rootDirectories
        self.openDocuments = openDocuments
        self.openDocumentVersions = openDocumentVersions
    }
}
