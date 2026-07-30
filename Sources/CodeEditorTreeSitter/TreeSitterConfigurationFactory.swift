import Foundation
import SwiftTreeSitter
import CodeEditorLanguageSupport

/// Builds highlight-only ``LanguageConfiguration`` values from ``LanguageRegistry``
/// registrations (parsers + query URLs) and catalog metadata on ``CodeLanguage``.
///
/// Used by the umbrella product and by individual language packs so hosts do not
/// need the full grammar set to highlight a single language.
public enum TreeSitterConfigurationFactory: Sendable {
    /// Errors while resolving a registered language into a Tree-sitter configuration.
    public enum Error: Swift.Error, Sendable {
        case queriesNotFound(String)
        case parserUnavailable(String)
    }

    /// Builds a `LanguageConfiguration` with **highlight** queries only.
    ///
    /// - Important: Only `highlights.scm` / `highlights-*.scm` (and parent highlights)
    ///   are compiled. Folds, indents, tags, locals, and injections are not merged
    ///   into the highlight query.
    public nonisolated static func languageConfiguration(
        for language: CodeLanguage
    ) throws -> LanguageConfiguration? {
        guard language.id != .plainText else { return nil }

        if let cached = Cache.shared.configuration(for: language.languageID) {
            return cached
        }

        guard let tsLanguage = language.tsLanguage else {
            throw Error.parserUnavailable(language.displayName)
        }

        var urls: [URL] = []
        if let parentID = language.parent,
           let parent = CodeLanguages.language(id: parentID),
           let parentHighlights = parent.queryURL(for: "highlights") {
            urls.append(parentHighlights)
        }
        if let highlights = language.queryURL(for: "highlights") {
            urls.append(highlights)
        }
        for extra in language.additionalQueries.sorted() where isHighlightQueryName(extra) {
            if let url = language.queryURL(for: extra) {
                urls.append(url)
            }
        }

        guard !urls.isEmpty else {
            throw Error.queriesNotFound(language.displayName)
        }

        let combined = try combinedQueryData(urls: urls)
        let query: Query
        do {
            query = try Query(language: tsLanguage, data: combined)
        } catch {
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
        Cache.shared.store(config, for: language.languageID)
        return config
    }

    public nonisolated static func languageConfiguration(
        id: String
    ) throws -> LanguageConfiguration? {
        guard let language = CodeLanguages.language(id: id) else { return nil }
        return try languageConfiguration(for: language)
    }

    // MARK: - Helpers

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
            throw Error.queriesNotFound("combined")
        }
        return data
    }

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var storage: [LanguageID: LanguageConfiguration] = [:]

        func configuration(for id: LanguageID) -> LanguageConfiguration? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]
        }

        func store(_ config: LanguageConfiguration, for id: LanguageID) {
            lock.lock()
            defer { lock.unlock() }
            storage[id] = config
        }
    }
}

/// ``TreeSitterConfigurationProviding`` backed by the shared ``LanguageRegistry``
/// and the static ``CodeLanguages`` catalog.
///
/// Safe for hosts that only link a subset of language packs: unregistered languages
/// simply fail to resolve parsers/queries.
public struct RegistryTreeSitterConfigurationProvider: TreeSitterConfigurationProviding {
    public init() {}

    public func codeLanguage(id: String) -> CodeLanguage? {
        CodeLanguages.language(id: id)
    }

    public func languageConfiguration(for languageID: String) throws -> LanguageConfiguration? {
        try TreeSitterConfigurationFactory.languageConfiguration(id: languageID)
    }
}
