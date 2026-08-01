import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import Foundation
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

    public static let requiredQueries: [String] = ["highlights"]

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var didRegister = false
        var registrationError: LanguagePackError?
    }

    private static let state = State()

    public static var lastError: LanguagePackError? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.registrationError
    }

    /// Registers the JSON parser, definition, and query resources into ``LanguageRegistry``.
    ///
    /// - Throws: ``LanguagePackError/missingQuery`` when required `.scm` resources are absent.
    @discardableResult
    public static func register() throws -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.didRegister else { return false }

        let language = CodeLanguage.json
        let registry = LanguageRegistry.shared
        var definition = LanguageDefinition(language)
        definition.allowsComments = false
        definition.fileExtensions.formUnion(["jsonc"])  // detect path; grammar is JSON (strict)
        definition.queryKinds = [.highlights, .folds, .indents, .locals]
        registry.register(definition)
        registry.registerParser(for: .json) { tree_sitter_json() }
        let tsName = language.tsName

        for query in requiredQueries {
            let (url, searched) = resolveQueryURL(tsName: tsName, query: query)
            guard url != nil else {
                let err = LanguagePackError.missingQuery(
                    language: .json,
                    query: query,
                    searchedPaths: searched
                )
                state.registrationError = err
                throw err
            }
        }

        registry.registerQueryProvider(for: .json) { queryName in
            resolveQueryURL(tsName: tsName, query: queryName).url
        }
        if TreeSitterLanguageEnvironment.configurationProvider == nil {
            TreeSitterLanguageEnvironment.install(RegistryTreeSitterConfigurationProvider())
        }
        state.didRegister = true
        state.registrationError = nil
        return true
    }

    private static func resolveQueryURL(tsName: String, query: String) -> (url: URL?, searched: [String]) {
        var searched: [String] = []
        let relative = "tree-sitter-\(tsName)/\(query).scm"
        if let base = Bundle.module.resourceURL {
            let a = base.appendingPathComponent("Resources").appendingPathComponent(relative)
            searched.append(a.path)
            if FileManager.default.fileExists(atPath: a.path) { return (a, searched) }
            let b = base.appendingPathComponent(relative)
            searched.append(b.path)
            if FileManager.default.fileExists(atPath: b.path) { return (b, searched) }
        }
        if let url = Bundle.module.url(
            forResource: query,
            withExtension: "scm",
            subdirectory: "Resources/tree-sitter-\(tsName)"
        ) {
            searched.append(url.path)
            return (url, searched)
        }
        if let url = Bundle.module.url(
            forResource: query,
            withExtension: "scm",
            subdirectory: "tree-sitter-\(tsName)"
        ) {
            searched.append(url.path)
            return (url, searched)
        }
        searched.append("Bundle.module:\(query).scm")
        return (nil, searched)
    }
}

private let _codeEditorLanguageJSONRegistration: Void = {
    do {
        _ = try CodeEditorLanguageJSON.register()
    } catch let error as LanguagePackError {
        LanguagePackRegistration.record(error)
    } catch {
        LanguagePackRegistration.record(
            .missingGrammarArtifact(language: .json, detail: String(describing: error))
        )
    }
}()
