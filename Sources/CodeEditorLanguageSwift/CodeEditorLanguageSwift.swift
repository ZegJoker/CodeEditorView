import Foundation
import CodeEditorLanguageSupport
import TreeSitterSwiftGrammar

/// Pilot language pack: Swift grammar + highlight queries.
///
/// Call ``register()`` (or import this module and rely on the static initializer)
/// before loading Tree-sitter configurations for Swift.
public enum CodeEditorLanguageSwift: Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var didRegister = false
    }

    private static let state = State()

    /// Registers the Swift parser, definition, and query resources into ``LanguageRegistry``.
    @discardableResult
    public static func register() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.didRegister else { return false }
        state.didRegister = true

        let language = CodeLanguage.swift
        let registry = LanguageRegistry.shared
        registry.register(LanguageDefinition(language))
        registry.registerParser(for: .swift) { tree_sitter_swift() }
        let tsName = language.tsName
        registry.registerQueryProvider(for: .swift) { queryName in
            queryURL(tsName: tsName, query: queryName)
        }
        return true
    }

    private static func queryURL(tsName: String, query: String) -> URL? {
        let relative = "tree-sitter-\(tsName)/\(query).scm"
        if let url = Bundle.module.resourceURL?
            .appendingPathComponent("Resources")
            .appendingPathComponent(relative),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.module.resourceURL?.appendingPathComponent(relative),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.module.url(
            forResource: query,
            withExtension: "scm",
            subdirectory: "Resources/tree-sitter-\(tsName)"
        ) {
            return url
        }
        return Bundle.module.url(
            forResource: query,
            withExtension: "scm",
            subdirectory: "tree-sitter-\(tsName)"
        )
    }
}

private let _codeEditorLanguageSwiftRegistration: Void = {
    _ = CodeEditorLanguageSwift.register()
}()
