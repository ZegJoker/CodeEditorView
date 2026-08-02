import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// How the find pattern is interpreted (Xcode-style textual match modes).
public enum SearchMatchMode: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Substring match anywhere.
    case contains
    /// Whole-word match (`\b…\b`).
    case matchesWord
    /// Pattern at the start of a line.
    case startsWith
    /// Pattern at the end of a line.
    case endsWith
    /// Pattern is a regular expression.
    case regularExpression

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .contains: return "Contains"
        case .matchesWord: return "Matches Word"
        case .startsWith: return "Starts With"
        case .endsWith: return "Ends With"
        case .regularExpression: return "Regular Expression"
        }
    }
}

public struct SearchQuery: Sendable, Hashable {
    public var pattern: String
    /// Primary match mode (Contains / Matches Word / Starts With / Ends With / Regex).
    public var matchMode: SearchMatchMode
    public var caseSensitive: Bool
    /// Legacy: prefer ``matchMode``. Still honored when `matchMode == .contains` and flags are set.
    public var isRegex: Bool
    /// Legacy: prefer ``matchMode``.
    public var wholeWord: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxFileBytes: Int
    public var maxResults: Int
    /// Optional wall-clock budget for the whole search (SRCH-N04 / SRCH-N06).
    public var timeBudgetNanoseconds: UInt64?

    public init(
        pattern: String,
        matchMode: SearchMatchMode = .contains,
        caseSensitive: Bool = false,
        isRegex: Bool = false,
        wholeWord: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = SearchQuery.defaultExcludes,
        maxFileBytes: Int = 1_000_000,
        maxResults: Int = 10_000,
        timeBudgetNanoseconds: UInt64? = nil
    ) {
        self.pattern = pattern
        // Prefer explicit matchMode; legacy flags upgrade contains when set.
        if matchMode != .contains {
            self.matchMode = matchMode
        } else if isRegex {
            self.matchMode = .regularExpression
        } else if wholeWord {
            self.matchMode = .matchesWord
        } else {
            self.matchMode = matchMode
        }
        self.caseSensitive = caseSensitive
        // Keep independent toggles so regex + whole-word can combine (Xcode Aa/ab/.* chips).
        self.isRegex = self.matchMode == .regularExpression || isRegex
        self.wholeWord = wholeWord || self.matchMode == .matchesWord
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxFileBytes = maxFileBytes
        self.maxResults = maxResults
        self.timeBudgetNanoseconds = timeBudgetNanoseconds
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

/// Why a candidate file was not searched (SRCH-N05 / SRCH-N06 / SRCH-N07).
public enum SearchSkipReason: String, Sendable, Hashable, Codable {
    case binary
    case encodingFailed
    case unsupportedEncoding
    case tooLarge
    case excluded
    case ignored
    case openFailed
    case matchLimitExceeded
    case regexBudgetExceeded
    case cancelled
}

public struct SearchSkip: Sendable, Hashable {
    public var path: String
    public var reason: SearchSkipReason
    public var detail: String?

    public init(path: String, reason: SearchSkipReason, detail: String? = nil) {
        self.path = path
        self.reason = reason
        self.detail = detail
    }
}

/// Precise completion counters (SRCH-N07).
///
/// - ``scanned`` / ``filesScanned``: files whose content was examined for matches
/// - ``matched``: files that produced ≥1 match (not equal to scanned)
/// - ``matchCount``: total match events emitted
public struct SearchCompletionMetrics: Sendable, Hashable {
    public var discovered: Int
    public var eligible: Int
    public var opened: Int
    public var decoded: Int
    public var scanned: Int
    public var matched: Int
    public var matchCount: Int
    public var skipped: Int
    public var failed: Int
    public var cancelled: Int

    public init(
        discovered: Int = 0,
        eligible: Int = 0,
        opened: Int = 0,
        decoded: Int = 0,
        scanned: Int = 0,
        matched: Int = 0,
        matchCount: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        cancelled: Int = 0
    ) {
        self.discovered = discovered
        self.eligible = eligible
        self.opened = opened
        self.decoded = decoded
        self.scanned = scanned
        self.matched = matched
        self.matchCount = matchCount
        self.skipped = skipped
        self.failed = failed
        self.cancelled = cancelled
    }

    /// Alias of ``scanned`` — never “files with matches” (SRCH-N07).
    public var filesScanned: Int { scanned }

    /// Files that produced matches.
    public var filesWithMatches: Int { matched }
}

public enum SearchEvent: Sendable {
    case progress(SearchProgress)
    case match(SearchMatch)
    case skipped(SearchSkip)
    case finished(SearchCompletionMetrics)
}

public enum SearchError: Error, Sendable, Equatable {
    case emptyPattern
    case invalidRegex(String)
    case cancelled
    case timeBudgetExceeded
}

/// Sendable snapshot for searching without holding MainActor Workspace.
public struct WorkspaceSearchContext: Sendable {
    public var rootDirectories: [URL]
    public var openDocuments: [DocumentURI: String]
    public var openDocumentVersions: [DocumentURI: DocumentVersion]
    public var openDocumentContentStates: [DocumentURI: DocumentContentStateID]
    public var openDocumentFileIdentities: [DocumentURI: DocumentFileIdentity]

    public init(
        rootDirectories: [URL] = [],
        openDocuments: [DocumentURI: String] = [:],
        openDocumentVersions: [DocumentURI: DocumentVersion] = [:],
        openDocumentContentStates: [DocumentURI: DocumentContentStateID] = [:],
        openDocumentFileIdentities: [DocumentURI: DocumentFileIdentity] = [:]
    ) {
        self.rootDirectories = rootDirectories
        self.openDocuments = openDocuments
        self.openDocumentVersions = openDocumentVersions
        self.openDocumentContentStates = openDocumentContentStates
        self.openDocumentFileIdentities = openDocumentFileIdentities
    }
}
