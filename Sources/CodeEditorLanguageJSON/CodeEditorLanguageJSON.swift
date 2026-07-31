import Foundation
import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import TreeSitterJsonGrammar

/// Pilot language pack: JSON grammar + highlight queries.
///
/// Call ``register()`` (or import this module and rely on the static initializer)
/// before loading Tree-sitter configurations for JSON.
///
/// JSONC (JSON with comments) is not a separate grammar here: use
/// ``LanguageDefinition/allowsComments`` on a host-provided definition when needed.
public enum CodeEditorLanguageJSON: Sendable {
    /// Pinned grammar commit (must match `scripts/grammars.tsv`).
    public static let grammarCommit = "001c28d7a29832b06b0e831ec77845553c89b56d"
    public static let grammarSourceURL = "https://github.com/tree-sitter/tree-sitter-json"
    public static let grammarParserSHA256 =
        "e8e1ff5df0d73e3b82574129724e68ef4fa0faf1b8c43dd3f5c1a84839f830ab"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var didRegister = false
    }

    private static let state = State()

    /// Registers the JSON parser, definition, and query resources into ``LanguageRegistry``.
    @discardableResult
    public static func register() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.didRegister else { return false }
        state.didRegister = true

        let language = CodeLanguage.json
        let registry = LanguageRegistry.shared
        var definition = LanguageDefinition(language)
        definition.allowsComments = false
        definition.fileExtensions.formUnion(["jsonc"]) // detect path; grammar is JSON (strict)
        definition.queryKinds = [.highlights, .folds, .indents, .locals]
        registry.register(definition)
        registry.registerParser(for: .json) { tree_sitter_json() }
        let tsName = language.tsName
        registry.registerQueryProvider(for: .json) { queryName in
            queryURL(tsName: tsName, query: queryName)
        }
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

private let _codeEditorLanguageJSONRegistration: Void = {
    _ = CodeEditorLanguageJSON.register()
}()
