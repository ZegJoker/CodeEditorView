import Foundation
import SwiftTreeSitter
import CodeEditorLanguageSupport
import CodeEditorTreeSitter

/// Highlight configuration factory (umbrella resource bundle + registered parsers).
extension CodeLanguages {
    /// Builds a `LanguageConfiguration` with **highlight** queries only.
    ///
    /// - Important: Only `highlights.scm` / `highlights-*.scm` (and parent highlights) are compiled.
    ///   Folds, indents, tags, locals, and injections are **not** merged into the highlight query —
    ///   doing so can hang query compilation on the main thread for large grammars.
    public nonisolated static func languageConfiguration(for language: CodeLanguage) throws -> LanguageConfiguration? {
        CodeEditorLanguages.bootstrap()

        guard language.id != .plainText else { return nil }

        if let cached = ConfigCache.shared.configuration(for: language.id) {
            return cached
        }

        guard let tsLanguage = language.tsLanguage else {
            throw LanguageLoadError.parserUnavailable(language.displayName)
        }

        var urls: [URL] = []
        // Parent language highlights first (e.g. C before C++).
        if let parentID = language.parent,
           let parent = Self.language(id: parentID),
           let parentHighlights = parent.queryURL(for: "highlights") {
            urls.append(parentHighlights)
        }
        if let highlights = language.queryURL(for: "highlights") {
            urls.append(highlights)
        }
        // Only highlight-variant scm files (e.g. highlights-jsx), never folds/indents/tags.
        for extra in language.additionalQueries.sorted() where Self.isHighlightQueryName(extra) {
            if let url = language.queryURL(for: extra) {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else {
            throw LanguageLoadError.queriesNotFound(language.displayName)
        }

        let combined = try combinedQueryData(urls: urls)
        let query: Query
        do {
            query = try Query(language: tsLanguage, data: combined)
        } catch {
            // Parent+child merge (or a mismatched scm) can fail node-type checks.
            // Fall back to this language's own highlights only so load never hangs/fails hard.
            if urls.count > 1, let own = language.queryURL(for: "highlights") {
                let ownData = try combinedQueryData(urls: [own])
                query = try Query(language: tsLanguage, data: ownData)
            } else {
                throw error
            }
        }
        let config = LanguageConfiguration(
            tsLanguage,
            name: language.displayName,
            queries: [.highlights: query]
        )
        ConfigCache.shared.store(config, for: language.id)
        return config
    }

    public nonisolated static func languageConfiguration(id: String) throws -> LanguageConfiguration? {
        CodeEditorLanguages.bootstrap()
        guard let language = language(id: id) else { return nil }
        return try languageConfiguration(for: language)
    }

    /// Preloads and caches highlight configuration off the caller's actor if desired.
    public nonisolated static func prefetchConfiguration(for language: CodeLanguage) async throws {
        _ = try languageConfiguration(for: language)
    }

    private nonisolated static func isHighlightQueryName(_ name: String) -> Bool {
        name == "highlights" || name.hasPrefix("highlights-") || name.hasPrefix("highlights_")
    }

    private nonisolated static func combinedQueryData(urls: [URL]) throws -> Data {
        var parts: [String] = []
        parts.reserveCapacity(urls.count)
        for url in urls {
            parts.append(try String(contentsOf: url, encoding: .utf8))
        }
        let joined = parts.joined(separator: "\n")
        guard let data = joined.data(using: .utf8), !data.isEmpty else {
            throw LanguageLoadError.queriesNotFound("combined")
        }
        return data
    }
}

public enum LanguageLoadError: Error, Sendable {
    case queriesNotFound(String)
    case parserUnavailable(String)
}

/// Thread-safe cache of compiled highlight configurations.
private final class ConfigCache: @unchecked Sendable {
    static let shared = ConfigCache()
    private let lock = NSLock()
    private var storage: [TreeSitterLanguageID: LanguageConfiguration] = [:]

    func configuration(for id: TreeSitterLanguageID) -> LanguageConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return storage[id]
    }

    func store(_ config: LanguageConfiguration, for id: TreeSitterLanguageID) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = config
    }
}
