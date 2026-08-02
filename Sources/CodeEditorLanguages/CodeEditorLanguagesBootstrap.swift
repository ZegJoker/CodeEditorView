import CodeEditorLanguageSupport
import CodeEditorTreeSitter
import Foundation
import SwiftTreeSitter
import TreeSitterAgdaGrammar
import TreeSitterBashGrammar
import TreeSitterCGrammar
import TreeSitterCSharpGrammar
import TreeSitterCppGrammar
import TreeSitterCssGrammar
import TreeSitterDartGrammar
import TreeSitterDockerfileGrammar
import TreeSitterElixirGrammar
import TreeSitterGoGrammar
import TreeSitterGoModGrammar
import TreeSitterHaskellGrammar
import TreeSitterHtmlGrammar
import TreeSitterJavaGrammar
import TreeSitterJavascriptGrammar
import TreeSitterJsdocGrammar
import TreeSitterJsonGrammar
import TreeSitterJuliaGrammar
import TreeSitterKotlinGrammar
import TreeSitterLuaGrammar
import TreeSitterMarkdownGrammar
import TreeSitterMarkdownInlineGrammar
import TreeSitterObjcGrammar
import TreeSitterOcamlGrammar
import TreeSitterPerlGrammar
import TreeSitterPhpGrammar
import TreeSitterPythonGrammar
import TreeSitterRegexGrammar
import TreeSitterRubyGrammar
import TreeSitterRustGrammar
import TreeSitterScalaGrammar
import TreeSitterSqlGrammar
import TreeSitterSwiftGrammar
import TreeSitterTomlGrammar
import TreeSitterTsxGrammar
import TreeSitterTypescriptGrammar
import TreeSitterVerilogGrammar
import TreeSitterYamlGrammar
import TreeSitterZigGrammar

/// Umbrella product entry: registers every built-in grammar + query bundle and
/// installs the Tree-sitter configuration provider.
///
/// Prefer ``bootstrap(into:)`` with a host-owned ``LanguageRegistry`` (LANG-N07).
/// ``bootstrap()`` targets ``LanguageRegistry/shared`` for compatibility.
public enum CodeEditorLanguages: Sendable {
    private enum Phase {
        case idle
        case inProgress
        case complete
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        /// Tracks process-wide shared bootstrap only.
        var phase: Phase = .idle
        /// Host-owned registries already bootstrapped (object identity).
        var bootstrappedRegistryIDs: Set<ObjectIdentifier> = []
    }

    private static let state = State()

    /// Registers all parsers, query providers, and the configuration provider into
    /// ``LanguageRegistry/shared``. Safe to call repeatedly.
    @discardableResult
    public static func bootstrap() -> Bool {
        bootstrap(into: .shared, installEnvironment: true)
    }

    /// Registers all built-in grammars into a host-owned registry (LANG-N07).
    ///
    /// Does **not** mutate global environment when `installEnvironment` is false,
    /// so multiple workspaces can own isolated registries.
    @discardableResult
    public static func bootstrap(
        into registry: LanguageRegistry,
        installEnvironment: Bool = false
    ) -> Bool {
        let isShared = registry === LanguageRegistry.shared
        if isShared {
            state.condition.lock()
            while state.phase == .inProgress {
                state.condition.wait()
            }
            if state.phase == .complete {
                state.condition.unlock()
                return false
            }
            state.phase = .inProgress
            state.condition.unlock()
        } else {
            state.condition.lock()
            let oid = ObjectIdentifier(registry)
            if state.bootstrappedRegistryIDs.contains(oid) {
                state.condition.unlock()
                return false
            }
            state.bootstrappedRegistryIDs.insert(oid)
            state.condition.unlock()
        }

        _ = codeEditorLanguagesModule
        if installEnvironment || isShared {
            installOnDemandBootstrapHook()
        }
        registerAllParsers(into: registry)
        registerAllQueryProvidersAndDefinitions(into: registry)
        if installEnvironment || isShared {
            TreeSitterLanguageEnvironment.install(
                RegistryTreeSitterConfigurationProvider(registry: registry)
            )
        }

        if isShared {
            state.condition.lock()
            state.phase = .complete
            state.condition.broadcast()
            state.condition.unlock()
        }
        return true
    }

    /// Installs the on-demand hook without registering parsers (idempotent).
    public static func installOnDemandBootstrapHook() {
        TreeSitterLanguageEnvironment.onDemandBootstrap = {
            CodeEditorLanguages.bootstrap()
        }
    }

    /// Test-only: clears bootstrap state so a fresh `bootstrap()` can run.
    /// Does not clear ``LanguageRegistry`` — call `LanguageRegistry.shared.removeAll()` first if needed.
    public static func resetBootstrapForTesting() {
        state.condition.lock()
        state.phase = .idle
        state.bootstrappedRegistryIDs.removeAll()
        state.condition.broadcast()
        state.condition.unlock()
    }
}

// MARK: - Parser registration

private func registerAllParsers(into registry: LanguageRegistry) {
    let pairs: [(LanguageID, @Sendable () -> OpaquePointer?)] = [
        (.agda, { tree_sitter_agda() }),
        (.bash, { tree_sitter_bash() }),
        (.c, { tree_sitter_c() }),
        (.cpp, { tree_sitter_cpp() }),
        (.cSharp, { tree_sitter_c_sharp() }),
        (.css, { tree_sitter_css() }),
        (.dart, { tree_sitter_dart() }),
        (.dockerfile, { tree_sitter_dockerfile() }),
        (.elixir, { tree_sitter_elixir() }),
        (.go, { tree_sitter_go() }),
        (.goMod, { tree_sitter_gomod() }),
        (.haskell, { tree_sitter_haskell() }),
        (.html, { tree_sitter_html() }),
        (.java, { tree_sitter_java() }),
        (.javascript, { tree_sitter_javascript() }),
        (.jsx, { tree_sitter_javascript() }),
        (.jsdoc, { tree_sitter_jsdoc() }),
        (.json, { tree_sitter_json() }),
        (.julia, { tree_sitter_julia() }),
        (.kotlin, { tree_sitter_kotlin() }),
        (.lua, { tree_sitter_lua() }),
        (.markdown, { tree_sitter_markdown() }),
        (.markdownInline, { tree_sitter_markdown_inline() }),
        (.objc, { tree_sitter_objc() }),
        (.ocaml, { tree_sitter_ocaml() }),
        (.perl, { tree_sitter_perl() }),
        (.php, { tree_sitter_php() }),
        (.python, { tree_sitter_python() }),
        (.regex, { tree_sitter_regex() }),
        (.ruby, { tree_sitter_ruby() }),
        (.rust, { tree_sitter_rust() }),
        (.scala, { tree_sitter_scala() }),
        (.sql, { tree_sitter_sql() }),
        (.swift, { tree_sitter_swift() }),
        (.toml, { tree_sitter_toml() }),
        (.tsx, { tree_sitter_tsx() }),
        (.typescript, { tree_sitter_typescript() }),
        (.verilog, { tree_sitter_verilog() }),
        (.yaml, { tree_sitter_yaml() }),
        (.zig, { tree_sitter_zig() }),
    ]

    for (id, factory) in pairs {
        // Owned built-in registration with static grammar symbol (LANG-N01 / N04 / N07).
        if registry.definition(for: id) == nil {
            // Definition registered in registerAllQueryProvidersAndDefinitions.
        }
        registry.registerParser(for: id, factory: factory)
    }
}

// MARK: - Query + definition registration

private func registerAllQueryProvidersAndDefinitions(into registry: LanguageRegistry) {
    for language in CodeLanguage.allLanguages {
        _ = registry.register(
            LanguageDefinition(language),
            owner: .builtIn,
            priority: LanguageDefinition(language).detectionPriority
        )
        let tsName = language.tsName
        let languageID = language.languageID
        registry.registerQueryProvider(for: languageID) { queryName in
            queryURLFromUmbrellaBundle(tsName: tsName, query: queryName)
        }
    }
}

/// Resolves `tree-sitter-{tsName}/{query}.scm` from this module's resource bundle.
func queryURLFromUmbrellaBundle(tsName: String, query: String) -> URL? {
    let relative = "tree-sitter-\(tsName)/\(query).scm"
    if let url = Bundle.module.resourceURL?
        .appendingPathComponent("Resources")
        .appendingPathComponent(relative),
        FileManager.default.fileExists(atPath: url.path)
    {
        return url
    }
    if let url = Bundle.module.resourceURL?.appendingPathComponent(relative),
        FileManager.default.fileExists(atPath: url.path)
    {
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
