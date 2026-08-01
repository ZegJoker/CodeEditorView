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
    public nonisolated static func languageConfiguration(for language: CodeLanguage) throws -> LanguageConfiguration? {
        CodeEditorLanguages.bootstrap()
        do {
            return try TreeSitterConfigurationFactory.languageConfiguration(for: language)
        } catch TreeSitterConfigurationFactory.Error.queriesNotFound(let name) {
            throw LanguageLoadError.queriesNotFound(name)
        } catch TreeSitterConfigurationFactory.Error.parserUnavailable(let name) {
            throw LanguageLoadError.parserUnavailable(name)
        }
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
}

public enum LanguageLoadError: Error, Sendable {
    case queriesNotFound(String)
    case parserUnavailable(String)
}
