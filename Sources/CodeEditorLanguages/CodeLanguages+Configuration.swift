import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import Foundation
import SwiftTreeSitter

/// Highlight configuration factory (umbrella bootstrap + shared registry factory).
extension CodeLanguages {
    /// Builds a `LanguageConfiguration` with **highlight** queries only.
    ///
    /// - Important: Only `highlights.scm` / `highlights-*.scm` (and parent highlights) are compiled.
    ///   Folds, indents, tags, locals, and injections are **not** merged into the highlight query —
    ///   doing so can hang query compilation on the main thread for large grammars.
    public nonisolated static func languageConfiguration(
        for language: CodeLanguage,
        registry: LanguageRegistry = .shared
    ) throws -> LanguageConfiguration? {
        if registry === LanguageRegistry.shared {
            CodeEditorLanguages.bootstrap()
        }
        do {
            return try TreeSitterConfigurationFactory.languageConfiguration(
                for: language, registry: registry)
        } catch TreeSitterConfigurationFactory.Error.queriesNotFound(let name) {
            throw LanguageLoadError.queriesNotFound(name)
        } catch TreeSitterConfigurationFactory.Error.parserUnavailable(let name) {
            throw LanguageLoadError.parserUnavailable(name)
        } catch TreeSitterConfigurationFactory.Error.malformedQuery(let name, let detail, _) {
            throw LanguageLoadError.malformedQuery(name, detail: detail)
        }
    }

    public nonisolated static func languageConfiguration(
        id: String,
        registry: LanguageRegistry = .shared
    ) throws -> LanguageConfiguration? {
        if registry === LanguageRegistry.shared {
            CodeEditorLanguages.bootstrap()
        }
        guard let language = language(id: id) else { return nil }
        return try languageConfiguration(for: language, registry: registry)
    }

    /// Preloads and caches highlight configuration off the caller's actor if desired.
    public nonisolated static func prefetchConfiguration(for language: CodeLanguage) async throws {
        _ = try languageConfiguration(for: language)
    }
}

public enum LanguageLoadError: Error, Sendable, Equatable {
    case queriesNotFound(String)
    case parserUnavailable(String)
    case malformedQuery(String, detail: String)
}
