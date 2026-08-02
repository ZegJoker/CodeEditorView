import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Builds highlight-only ``LanguageConfiguration`` values from ``LanguageRegistry``
/// registrations (parsers + query URLs) and catalog metadata on ``CodeLanguage``.
///
/// Used by the umbrella product and by individual language packs so hosts do not
/// need the full grammar set to highlight a single language.
public enum TreeSitterConfigurationFactory: Sendable {
    /// Errors while resolving a registered language into a Tree-sitter configuration.
    public enum Error: Swift.Error, Sendable, Equatable {
        case queriesNotFound(String)
        case parserUnavailable(String)
        case malformedQuery(language: String, detail: String, path: String?)
    }

    /// Builds a `LanguageConfiguration` with **highlight** queries only.
    ///
    /// Malformed present queries fail closed with ``Error/malformedQuery`` (LANG-N02).
    /// No silent `try?` fallback that omits a broken query.
    ///
    /// - Important: Only `highlights.scm` / `highlights-*.scm` (and parent highlights)
    ///   are compiled. Folds, indents, tags, locals, and injections are not merged
    ///   into the highlight query.
    public nonisolated static func languageConfiguration(
        for language: CodeLanguage,
        registry: LanguageRegistry = .shared
    ) throws -> LanguageConfiguration? {
        guard language.id != .plainText else { return nil }

        if let cached = Cache.shared.configuration(for: language.languageID) {
            return cached
        }

        guard let tsLanguage = language.tsLanguage(registry: registry) else {
            throw Error.parserUnavailable(language.displayName)
        }

        let combinedText: String
        do {
            combinedText = try QuerySetLoader.combinedHighlightsSource(
                language: language, registry: registry)
        } catch let error as QuerySetError {
            switch error {
            case .missingRequired:
                throw Error.queriesNotFound(language.displayName)
            case .malformed(_, _, let path, let detail):
                throw Error.malformedQuery(
                    language: language.displayName,
                    detail: detail,
                    path: path
                )
            case .unreadable(_, _, let path):
                throw Error.malformedQuery(
                    language: language.displayName,
                    detail: error.description,
                    path: path
                )
            case .oversized:
                throw Error.malformedQuery(
                    language: language.displayName,
                    detail: error.description,
                    path: nil
                )
            }
        }

        guard let combined = combinedText.data(using: .utf8), !combined.isEmpty else {
            throw Error.queriesNotFound(language.displayName)
        }

        let query: Query
        do {
            query = try Query(language: tsLanguage, data: combined)
        } catch {
            // Fail closed: do not silently fall back to omitting parent merges
            // when the combined query is malformed (LANG-N02).
            throw Error.malformedQuery(
                language: language.displayName,
                detail: String(describing: error),
                path: registry.queryURL(for: language.languageID, kind: .highlights)?.path
            )
        }

        let config = LanguageConfiguration(
            tsLanguage,
            name: language.displayName,
            queries: [.highlights: query]
        )
        let identity = GrammarIdentity(languageID: language.languageID)
        Cache.shared.store(config, for: language.languageID, identity: identity)
        return config
    }

    public nonisolated static func languageConfiguration(
        id: String,
        registry: LanguageRegistry = .shared
    ) throws -> LanguageConfiguration? {
        guard let language = CodeLanguages.language(id: id) else { return nil }
        return try languageConfiguration(for: language, registry: registry)
    }

    /// Clears the process-wide configuration cache (tests / grammar reload).
    public nonisolated static func clearCache() {
        Cache.shared.clear()
    }

    // MARK: - Cache

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var storage: [LanguageID: (config: LanguageConfiguration, identity: GrammarIdentity)] = [:]

        func configuration(for id: LanguageID) -> LanguageConfiguration? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]?.config
        }

        func store(_ config: LanguageConfiguration, for id: LanguageID, identity: GrammarIdentity) {
            lock.lock()
            defer { lock.unlock() }
            storage[id] = (config, identity)
        }

        func identity(for id: LanguageID) -> GrammarIdentity? {
            lock.lock()
            defer { lock.unlock() }
            return storage[id]?.identity
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            storage.removeAll()
        }
    }
}

/// ``TreeSitterConfigurationProviding`` backed by an explicit ``LanguageRegistry``
/// and the static ``CodeLanguages`` catalog (LANG-N07 host-owned registry).
///
/// Safe for hosts that only link a subset of language packs: unregistered languages
/// simply fail to resolve parsers/queries.
public struct RegistryTreeSitterConfigurationProvider: TreeSitterConfigurationProviding {
    public let registry: LanguageRegistry

    public init(registry: LanguageRegistry = .shared) {
        self.registry = registry
    }

    public func codeLanguage(id: String) -> CodeLanguage? {
        CodeLanguages.language(id: id)
    }

    public func languageConfiguration(for languageID: String) throws -> LanguageConfiguration? {
        try TreeSitterConfigurationFactory.languageConfiguration(id: languageID, registry: registry)
    }
}
