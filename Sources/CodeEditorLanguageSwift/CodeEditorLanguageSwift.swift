import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import Foundation
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

    /// Query basenames required for a successful pack registration.
    public static let requiredQueries: [String] = ["highlights"]

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var didRegister = false
        var registrationError: LanguagePackError?
    }

    private static let state = State()

    /// Last registration error, if static or prior ``register()`` failed closed.
    public static var lastError: LanguagePackError? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.registrationError
    }

    /// Registers the Swift parser, definition, and query resources into ``LanguageRegistry``.
    ///
    /// - Throws: ``LanguagePackError/missingQuery`` when required `.scm` resources are absent.
    @discardableResult
    public static func register() throws -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !state.didRegister else { return false }

        let language = CodeLanguage.swift
        let registry = LanguageRegistry.shared
        var definition = LanguageDefinition(language)
        definition.filenames = ["package.swift"]
        definition.preferredLanguageServers = ["sourcekit-lsp"]
        definition.queryKinds = [.highlights, .folds, .indents, .injections, .locals, .outline, .textobjects, .tags]
        registry.register(definition)
        registry.registerParser(for: .swift) { tree_sitter_swift() }
        let tsName = language.tsName

        // Validate required query artifacts before publishing the provider.
        for query in requiredQueries {
            let (url, searched) = resolveQueryURL(tsName: tsName, query: query)
            guard url != nil else {
                let err = LanguagePackError.missingQuery(
                    language: .swift,
                    query: query,
                    searchedPaths: searched
                )
                state.registrationError = err
                throw err
            }
        }

        registry.registerQueryProvider(for: .swift) { queryName in
            resolveQueryURL(tsName: tsName, query: queryName).url
        }
        // Standalone pack hosts: install registry-backed config if nothing else is installed.
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

private let _codeEditorLanguageSwiftRegistration: Void = {
    do {
        _ = try CodeEditorLanguageSwift.register()
    } catch let error as LanguagePackError {
        LanguagePackRegistration.record(error)
    } catch {
        LanguagePackRegistration.record(
            .missingGrammarArtifact(language: .swift, detail: String(describing: error))
        )
    }
}()
