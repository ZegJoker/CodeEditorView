import Foundation
import CodeEditorLanguageSupport

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
}

/// Loads query source text by kind from a registry provider.
public enum QuerySetLoader: Sendable {
    public static func loadSources(
        languageID: LanguageID,
        kinds: Set<QueryKind>,
        registry: LanguageRegistry = .shared,
        limits: TreeSitterQueryLimits = .default
    ) -> (sources: [QueryKind: String], diagnostics: [QuerySetDiagnostic]) {
        var sources: [QueryKind: String] = [:]
        var diagnostics: [QuerySetDiagnostic] = []
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let url = registry.queryURL(for: languageID, kind: kind) else {
                if kind == .highlights {
                    diagnostics.append(.missing(kind))
                }
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                diagnostics.append(.unreadable(kind, path: url.path))
                continue
            }
            let bytes = text.utf8.count
            if bytes > limits.maxCombinedQueryBytes {
                diagnostics.append(.oversized(kind, bytes: bytes))
                continue
            }
            sources[kind] = text
        }
        return (sources, diagnostics)
    }

    /// Combined highlights text including optional parent highlights.
    public static func combinedHighlightsSource(
        language: CodeLanguage,
        registry: LanguageRegistry = .shared,
        limits: TreeSitterQueryLimits = .default
    ) throws -> String {
        var parts: [String] = []
        var total = 0
        if let parentID = language.parent,
           let parent = CodeLanguages.language(id: parentID),
           let url = registry.queryURL(for: parent.languageID, kind: .highlights),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            total += text.utf8.count
            parts.append(text)
        }
        if let url = registry.queryURL(for: language.languageID, kind: .highlights),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            total += text.utf8.count
            parts.append(text)
        }
        for name in language.additionalQueries.sorted()
        where name == "highlights" || name.hasPrefix("highlights-") || name.hasPrefix("highlights_") {
            if let url = registry.queryURL(for: language.languageID, query: name),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                total += text.utf8.count
                parts.append(text)
            }
        }
        guard !parts.isEmpty else {
            throw TreeSitterConfigurationFactory.Error.queriesNotFound(language.displayName)
        }
        if total > limits.maxCombinedQueryBytes {
            throw TreeSitterConfigurationFactory.Error.queriesNotFound(
                "\(language.displayName) highlights exceed size limit"
            )
        }
        return parts.joined(separator: "\n")
    }
}
