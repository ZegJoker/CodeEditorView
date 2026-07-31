import Foundation
import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import TreeSitterSwiftGrammar

/// Pilot language pack: Swift grammar + highlight queries.
///
/// Call ``register()`` (or import this module and rely on the static initializer)
/// before loading Tree-sitter configurations for Swift.
public enum CodeEditorLanguageSwift: Sendable {
    /// Pinned grammar commit (must match `scripts/grammars.tsv`).
    public static let grammarCommit = "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5"
    public static let grammarSourceURL = "https://github.com/alex-pinkus/tree-sitter-swift"
    public static let grammarParserSHA256 =
        "cd57689a482a162c8f5bb2b33ae199adbdbcdc3fb737acec3dba02d07dbd20a6"

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
        var definition = LanguageDefinition(language)
        definition.filenames = ["package.swift"]
        definition.preferredLanguageServers = ["sourcekit-lsp"]
        definition.queryKinds = [.highlights, .folds, .indents, .injections, .locals, .outline, .textobjects, .tags]
        registry.register(definition)
        registry.registerParser(for: .swift) { tree_sitter_swift() }
        let tsName = language.tsName
        registry.registerQueryProvider(for: .swift) { queryName in
            queryURL(tsName: tsName, query: queryName)
        }
        // Standalone pack hosts: install registry-backed config if nothing else is installed.
        if TreeSitterLanguageEnvironment.configurationProvider == nil {
            TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
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
