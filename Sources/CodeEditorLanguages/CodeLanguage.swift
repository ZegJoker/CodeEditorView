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

/// Metadata for a programming language and its tree-sitter resources.
///
/// Query files live under `Resources/tree-sitter-{tsName}/` (CodeEditLanguages layout).
/// Parsers are multiplatform vendored C targets under `Grammars/src/` (not a binary container).
public struct CodeLanguage: Hashable, Sendable, Identifiable {
    public var id: TreeSitterLanguageID
    /// tree-sitter resource directory name (`tree-sitter-{tsName}`).
    public var tsName: String
    public var displayName: String
    public var extensions: Set<String>
    public var lineComment: String
    public var rangeComment: (String, String)
    /// Additional query basenames to merge (e.g. `"folds"`, `"locals"`). `highlights` is always loaded.
    public var additionalQueries: Set<String>
    /// Optional parent language whose `highlights.scm` is prepended (e.g. C for C++).
    public var parent: TreeSitterLanguageID?
    public var aliases: Set<String>

    public init(
        id: TreeSitterLanguageID,
        tsName: String,
        displayName: String,
        extensions: Set<String>,
        lineComment: String = "",
        rangeComment: (String, String) = ("", ""),
        additionalQueries: Set<String> = [],
        parent: TreeSitterLanguageID? = nil,
        aliases: Set<String> = []
    ) {
        self.id = id
        self.tsName = tsName
        self.displayName = displayName
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.lineComment = lineComment
        self.rangeComment = rangeComment
        self.additionalQueries = additionalQueries
        self.parent = parent
        self.aliases = Set(aliases.map { $0.lowercased() })
    }

    public static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Queries (CEL layout)

    /// URL for a query file: `tree-sitter-{tsName}/{name}.scm`
    public func queryURL(for name: String = "highlights") -> URL? {
        Self.queryURL(tsName: tsName, query: name)
    }

    public static func queryURL(tsName: String, query: String) -> URL? {
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

    /// Tree-sitter language for this definition, if a grammar is linked.
    public var tsLanguage: Language? {
        guard let pointer = Self.languagePointer(for: id) else { return nil }
        return Language(language: pointer)
    }

    private static func languagePointer(for id: TreeSitterLanguageID) -> OpaquePointer? {
        // C imports surface these as OpaquePointer? via our public headers.
        switch id {
        case .agda: return tree_sitter_agda()
        case .bash: return tree_sitter_bash()
        case .c: return tree_sitter_c()
        case .cpp: return tree_sitter_cpp()
        case .cSharp: return tree_sitter_c_sharp()
        case .css: return tree_sitter_css()
        case .dart: return tree_sitter_dart()
        case .dockerfile: return tree_sitter_dockerfile()
        case .elixir: return tree_sitter_elixir()
        case .go: return tree_sitter_go()
        case .goMod: return tree_sitter_gomod()
        case .haskell: return tree_sitter_haskell()
        case .html: return tree_sitter_html()
        case .java: return tree_sitter_java()
        case .javascript, .jsx: return tree_sitter_javascript()
        case .jsdoc: return tree_sitter_jsdoc()
        case .json: return tree_sitter_json()
        case .julia: return tree_sitter_julia()
        case .kotlin: return tree_sitter_kotlin()
        case .lua: return tree_sitter_lua()
        case .markdown: return tree_sitter_markdown()
        case .markdownInline: return tree_sitter_markdown_inline()
        case .objc: return tree_sitter_objc()
        case .ocaml: return tree_sitter_ocaml()
        case .perl: return tree_sitter_perl()
        case .php: return tree_sitter_php()
        case .python: return tree_sitter_python()
        case .regex: return tree_sitter_regex()
        case .ruby: return tree_sitter_ruby()
        case .rust: return tree_sitter_rust()
        case .scala: return tree_sitter_scala()
        case .sql: return tree_sitter_sql()
        case .swift: return tree_sitter_swift()
        case .toml: return tree_sitter_toml()
        case .tsx: return tree_sitter_tsx()
        case .typescript: return tree_sitter_typescript()
        case .verilog: return tree_sitter_verilog()
        case .yaml: return tree_sitter_yaml()
        case .zig: return tree_sitter_zig()
        case .plainText: return nil
        }
    }
}
