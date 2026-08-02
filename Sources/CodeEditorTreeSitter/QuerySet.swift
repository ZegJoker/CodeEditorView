import CodeEditorLanguageSupport
import Foundation

/// Limits applied when loading / executing Tree-sitter queries.
public struct TreeSitterQueryLimits: Sendable, Hashable {
    public var maxCombinedQueryBytes: Int
    public var maxInjectionDepth: Int
    public var maxHighlightCaptures: Int

    public init(
        maxCombinedQueryBytes: Int = 512 * 1024,
        maxInjectionDepth: Int = 4,
        maxHighlightCaptures: Int = 50_000
    ) {
        self.maxCombinedQueryBytes = maxCombinedQueryBytes
        self.maxInjectionDepth = maxInjectionDepth
        self.maxHighlightCaptures = maxHighlightCaptures
    }

    public static let `default` = TreeSitterQueryLimits()
}

/// Provenance key for grammar + query cache entries.
public struct GrammarIdentity: Sendable, Hashable, Codable {
    public var languageID: LanguageID
    public var sourceRevision: String?
    public var parserContentHash: String?

    public init(
        languageID: LanguageID,
        sourceRevision: String? = nil,
        parserContentHash: String? = nil
    ) {
        self.languageID = languageID
        self.sourceRevision = sourceRevision
        self.parserContentHash = parserContentHash
    }
}

public enum QuerySetDiagnostic: Sendable, Hashable, Equatable {
    case missing(QueryKind)
    case unreadable(QueryKind, path: String)
    case oversized(QueryKind, bytes: Int)
    case malformed(QueryKind, path: String?, detail: String)
}

/// Fail-closed query load/compile errors (LANG-N02).
public enum QuerySetError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(language: LanguageID, kind: QueryKind, path: String)
    case oversized(language: LanguageID, kind: QueryKind, bytes: Int, limit: Int)
    case malformed(language: LanguageID, kind: QueryKind, path: String?, detail: String)
    case missingRequired(language: LanguageID, kind: QueryKind)

    public var description: String {
        switch self {
        case .unreadable(let language, let kind, let path):
            return "Query \(kind.rawValue) for \(language.rawValue) unreadable at \(path)"
        case .oversized(let language, let kind, let bytes, let limit):
            return "Query \(kind.rawValue) for \(language.rawValue) oversized (\(bytes) > \(limit))"
        case .malformed(let language, let kind, let path, let detail):
            let loc = path.map { " at \($0)" } ?? ""
            return "Query \(kind.rawValue) for \(language.rawValue) malformed\(loc): \(detail)"
        case .missingRequired(let language, let kind):
            return "Required query \(kind.rawValue) missing for \(language.rawValue)"
        }
    }

    public var asLanguagePackError: LanguagePackError {
        switch self {
        case .unreadable(let language, let kind, let path):
            return .unreadableQuery(language: language, query: kind.rawValue, path: path)
        case .oversized(let language, let kind, let bytes, _):
            return .malformedQuery(
                language: language,
                query: kind.rawValue,
                path: nil,
                detail: "oversized (\(bytes) bytes)"
            )
        case .malformed(let language, let kind, let path, let detail):
            return .malformedQuery(
                language: language, query: kind.rawValue, path: path, detail: detail)
        case .missingRequired(let language, let kind):
            return .missingQuery(language: language, query: kind.rawValue, searchedPaths: [])
        }
    }
}

/// Loads query source text by kind from a registry provider.
public enum QuerySetLoader: Sendable {
    /// Loads sources for the given kinds.
    ///
    /// - Missing **optional** kinds yield a `.missing` diagnostic and are omitted.
    /// - A **present** file that is unreadable or oversized throws (LANG-N02 fail closed).
    /// - Highlights is required when included in `kinds`.
    public static func loadSources(
        languageID: LanguageID,
        kinds: Set<QueryKind>,
        registry: LanguageRegistry = .shared,
        limits: TreeSitterQueryLimits = .default,
        required: Set<QueryKind> = [.highlights]
    ) throws -> (sources: [QueryKind: String], diagnostics: [QuerySetDiagnostic]) {
        var sources: [QueryKind: String] = [:]
        var diagnostics: [QuerySetDiagnostic] = []
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let url = registry.queryURL(for: languageID, kind: kind) else {
                if required.contains(kind) {
                    diagnostics.append(.missing(kind))
                    throw QuerySetError.missingRequired(language: languageID, kind: kind)
                }
                diagnostics.append(.missing(kind))
                continue
            }
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                diagnostics.append(.unreadable(kind, path: url.path))
                throw QuerySetError.unreadable(
                    language: languageID, kind: kind, path: url.path)
            }
            let bytes = text.utf8.count
            if bytes > limits.maxCombinedQueryBytes {
                diagnostics.append(.oversized(kind, bytes: bytes))
                throw QuerySetError.oversized(
                    language: languageID,
                    kind: kind,
                    bytes: bytes,
                    limit: limits.maxCombinedQueryBytes
                )
            }
            sources[kind] = text
        }
        return (sources, diagnostics)
    }

    /// Non-throwing soft load retained only for optional feature discovery in tests.
    /// Prefer ``loadSources(languageID:kinds:registry:limits:required:)``.
    public static func loadSourcesSoft(
        languageID: LanguageID,
        kinds: Set<QueryKind>,
        registry: LanguageRegistry = .shared,
        limits: TreeSitterQueryLimits = .default
    ) -> (sources: [QueryKind: String], diagnostics: [QuerySetDiagnostic]) {
        (try? loadSources(
            languageID: languageID,
            kinds: kinds,
            registry: registry,
            limits: limits,
            required: []
        )) ?? ([:], kinds.map { .missing($0) })
    }

    /// Combined highlights text including optional parent highlights.
    /// Fail closed on unreadable present files (LANG-N02).
    public static func combinedHighlightsSource(
        language: CodeLanguage,
        registry: LanguageRegistry = .shared,
        limits: TreeSitterQueryLimits = .default
    ) throws -> String {
        var parts: [String] = []
        var total = 0
        if let parentID = language.parent,
            let parent = CodeLanguages.language(id: parentID)
        {
            if let url = registry.queryURL(for: parent.languageID, kind: .highlights) {
                let text = try readUTF8(url: url, language: parent.languageID, kind: .highlights)
                total += text.utf8.count
                parts.append(text)
            }
        }
        if let url = registry.queryURL(for: language.languageID, kind: .highlights) {
            let text = try readUTF8(url: url, language: language.languageID, kind: .highlights)
            total += text.utf8.count
            parts.append(text)
        }
        for name in language.additionalQueries.sorted()
        where name == "highlights" || name.hasPrefix("highlights-") || name.hasPrefix("highlights_") {
            if let url = registry.queryURL(for: language.languageID, query: name) {
                let text: String
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw QuerySetError.unreadable(
                        language: language.languageID,
                        kind: .highlights,
                        path: url.path
                    )
                }
                total += text.utf8.count
                parts.append(text)
            }
        }
        guard !parts.isEmpty else {
            throw QuerySetError.missingRequired(language: language.languageID, kind: .highlights)
        }
        if total > limits.maxCombinedQueryBytes {
            throw QuerySetError.oversized(
                language: language.languageID,
                kind: .highlights,
                bytes: total,
                limit: limits.maxCombinedQueryBytes
            )
        }
        return parts.joined(separator: "\n")
    }

    private static func readUTF8(
        url: URL,
        language: LanguageID,
        kind: QueryKind
    ) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw QuerySetError.unreadable(language: language, kind: kind, path: url.path)
        }
    }
}
