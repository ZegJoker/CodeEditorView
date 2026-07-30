import Foundation
import SwiftTreeSitter
import CodeEditorLanguageSupport
import CodeEditorTreeSitter

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
public enum CodeEditorLanguages: Sendable {
    private enum Phase {
        case idle
        case inProgress
        case complete
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var phase: Phase = .idle
    }

    private static let state = State()

    /// Registers all parsers, query providers, and the configuration provider.
    /// Safe to call repeatedly (subsequent calls wait for an in-flight bootstrap, then no-op).
    @discardableResult
    public static func bootstrap() -> Bool {
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

        installOnDemandBootstrapHook()
        registerAllParsers()
        registerAllQueryProvidersAndDefinitions()
        TreeSitterLanguageEnvironment.install(UmbrellaConfigurationProvider())

        state.condition.lock()
        state.phase = .complete
        state.condition.broadcast()
        state.condition.unlock()
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
        state.condition.broadcast()
        state.condition.unlock()
    }
}



// MARK: - Configuration provider

private struct UmbrellaConfigurationProvider: TreeSitterConfigurationProviding {
    func codeLanguage(id: String) -> CodeLanguage? {
        CodeLanguages.language(id: id)
    }

    func languageConfiguration(for languageID: String) throws -> LanguageConfiguration? {
        try CodeLanguages.languageConfiguration(id: languageID)
    }
}

// MARK: - Parser registration

private func registerAllParsers() {
    let registry = LanguageRegistry.shared

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
        registry.registerParser(for: id, factory: factory)
    }
}

// MARK: - Query + definition registration

private func registerAllQueryProvidersAndDefinitions() {
    let registry = LanguageRegistry.shared
    for language in CodeLanguage.allLanguages {
        registry.register(LanguageDefinition(language))
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
