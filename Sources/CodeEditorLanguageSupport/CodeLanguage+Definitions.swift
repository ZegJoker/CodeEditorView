import Foundation

// Language catalog aligned with CodeEditLanguages (full set).
// Queries: Sources/CodeEditorLanguages/Resources/tree-sitter-{tsName}/*.scm
// Parsers: vendored multiplatform C under Grammars/src (not CEL binary container).

extension CodeLanguage {
    public static let allLanguages: [CodeLanguage] = [
        .agda, .bash, .c, .cpp, .cSharp, .css, .dart, .dockerfile, .elixir,
        .go, .goMod, .haskell, .html, .java, .javascript, .jsdoc, .json, .jsx,
        .julia, .kotlin, .lua, .markdown, .markdownInline, .objc, .ocaml,
        .perl, .php, .python, .regex, .ruby, .rust, .scala, .sql, .swift,
        .toml, .tsx, .typescript, .verilog, .yaml, .zig, .plainText,
    ]

    /// Languages with a tree-sitter parser currently registered in ``LanguageRegistry``.
    public static var highlightable: [CodeLanguage] {
        allLanguages.filter {
            $0.id != .plainText && LanguageRegistry.shared.hasParser(for: $0.languageID)
        }
    }

    public static let plainText = CodeLanguage(
        id: .plainText,
        tsName: "plaintext",
        displayName: "Plain Text",
        extensions: ["txt", "text"]
    )

    public static let agda = CodeLanguage(
        id: .agda, tsName: "agda", displayName: "Agda",
        extensions: ["agda"],
        lineComment: "--", rangeComment: ("{-", "-}"),
        additionalQueries: ["folds", "injections"]
    )

    public static let bash = CodeLanguage(
        id: .bash, tsName: "bash", displayName: "Bash",
        extensions: ["sh", "bash"],
        lineComment: "#",
        additionalQueries: ["folds", "injections", "locals"],
        aliases: ["shell", "zsh"]
    )

    public static let c = CodeLanguage(
        id: .c, tsName: "c", displayName: "C",
        extensions: ["c", "h"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"]
    )

    public static let cpp = CodeLanguage(
        id: .cpp, tsName: "cpp", displayName: "C++",
        extensions: ["cc", "cpp", "c++", "hpp", "hh", "hxx"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        parent: .c,
        aliases: ["c++"]
    )

    public static let cSharp = CodeLanguage(
        id: .cSharp, tsName: "c-sharp", displayName: "C#",
        extensions: ["cs"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "injections", "locals", "tags"],
        aliases: ["csharp", "cs"]
    )

    public static let css = CodeLanguage(
        id: .css, tsName: "css", displayName: "CSS",
        extensions: ["css"],
        rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections"]
    )

    public static let dart = CodeLanguage(
        id: .dart, tsName: "dart", displayName: "Dart",
        extensions: ["dart"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"]
    )

    public static let dockerfile = CodeLanguage(
        id: .dockerfile, tsName: "dockerfile", displayName: "Dockerfile",
        extensions: ["dockerfile"],
        lineComment: "#",
        additionalQueries: ["injections"],
        aliases: ["docker"]
    )

    public static let elixir = CodeLanguage(
        id: .elixir, tsName: "elixir", displayName: "Elixir",
        extensions: ["ex", "exs"],
        lineComment: "#",
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"]
    )

    public static let go = CodeLanguage(
        id: .go, tsName: "go", displayName: "Go",
        extensions: ["go"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        aliases: ["golang"]
    )

    public static let goMod = CodeLanguage(
        id: .goMod, tsName: "go-mod", displayName: "Go Mod",
        extensions: ["mod"],
        lineComment: "//", rangeComment: ("/*", "*/")
    )

    public static let haskell = CodeLanguage(
        id: .haskell, tsName: "haskell", displayName: "Haskell",
        extensions: ["hs"],
        lineComment: "--", rangeComment: ("{-", "-}"),
        additionalQueries: ["folds", "injections", "locals"]
    )

    public static let html = CodeLanguage(
        id: .html, tsName: "html", displayName: "HTML",
        extensions: ["html", "htm", "shtml"],
        rangeComment: ("<!--", "-->"),
        additionalQueries: ["folds", "indents", "injections", "locals"]
    )

    public static let java = CodeLanguage(
        id: .java, tsName: "java", displayName: "Java",
        extensions: ["java", "jav"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"]
    )

    public static let javascript = CodeLanguage(
        id: .javascript, tsName: "javascript", displayName: "JavaScript",
        extensions: ["js", "cjs", "mjs"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        aliases: ["js"]
    )

    public static let jsx = CodeLanguage(
        id: .jsx, tsName: "javascript", displayName: "JSX",
        extensions: ["jsx"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags", "highlights-jsx"]
    )

    public static let jsdoc = CodeLanguage(
        id: .jsdoc, tsName: "jsdoc", displayName: "JSDoc",
        extensions: [],
        lineComment: "", rangeComment: ("/**", "*/")
    )

    public static let json = CodeLanguage(
        id: .json, tsName: "json", displayName: "JSON",
        extensions: ["json"],
        aliases: ["jsonc"]
    )

    public static let julia = CodeLanguage(
        id: .julia, tsName: "julia", displayName: "Julia",
        extensions: ["jl"],
        lineComment: "#", rangeComment: ("#=", "=#")
    )

    public static let kotlin = CodeLanguage(
        id: .kotlin, tsName: "kotlin", displayName: "Kotlin",
        extensions: ["kt", "kts"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "injections", "locals"]
    )

    public static let lua = CodeLanguage(
        id: .lua, tsName: "lua", displayName: "Lua",
        extensions: ["lua"],
        lineComment: "--", rangeComment: ("--[[", "]]"),
        additionalQueries: ["folds", "indents", "injections", "locals"]
    )

    public static let markdown = CodeLanguage(
        id: .markdown, tsName: "markdown", displayName: "Markdown",
        extensions: ["md", "markdown", "mdx"],
        additionalQueries: ["injections"]
    )

    public static let markdownInline = CodeLanguage(
        id: .markdownInline, tsName: "markdown-inline", displayName: "Markdown Inline",
        extensions: []
    )

    public static let objc = CodeLanguage(
        id: .objc, tsName: "objc", displayName: "Objective-C",
        extensions: ["m", "mm"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        parent: .c,
        aliases: ["objective-c", "objectivec"]
    )

    public static let ocaml = CodeLanguage(
        id: .ocaml, tsName: "ocaml", displayName: "OCaml",
        extensions: ["ml", "mli"],
        rangeComment: ("(*", "*)"),
        additionalQueries: ["folds", "injections", "locals"]
    )

    public static let perl = CodeLanguage(
        id: .perl, tsName: "perl", displayName: "Perl",
        extensions: ["pl", "pm"],
        lineComment: "#"
    )

    public static let php = CodeLanguage(
        id: .php, tsName: "php", displayName: "PHP",
        extensions: ["php"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "tags"]
    )

    public static let python = CodeLanguage(
        id: .python, tsName: "python", displayName: "Python",
        extensions: ["py", "pyw"],
        lineComment: "#",
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        aliases: ["py"]
    )

    public static let regex = CodeLanguage(
        id: .regex, tsName: "regex", displayName: "Regex",
        extensions: []
    )

    public static let ruby = CodeLanguage(
        id: .ruby, tsName: "ruby", displayName: "Ruby",
        extensions: ["rb", "ru"],
        lineComment: "#",
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"]
    )

    public static let rust = CodeLanguage(
        id: .rust, tsName: "rust", displayName: "Rust",
        extensions: ["rs"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "injections", "locals"]
    )

    public static let scala = CodeLanguage(
        id: .scala, tsName: "scala", displayName: "Scala",
        extensions: ["scala", "sc"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "injections"]
    )

    public static let sql = CodeLanguage(
        id: .sql, tsName: "sql", displayName: "SQL",
        extensions: ["sql"],
        lineComment: "--", rangeComment: ("/*", "*/")
    )

    public static let swift = CodeLanguage(
        id: .swift, tsName: "swift", displayName: "Swift",
        extensions: ["swift"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals"]
    )

    public static let toml = CodeLanguage(
        id: .toml, tsName: "toml", displayName: "TOML",
        extensions: ["toml"],
        lineComment: "#"
    )

    public static let typescript = CodeLanguage(
        id: .typescript, tsName: "typescript", displayName: "TypeScript",
        extensions: ["ts", "mts", "cts"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        // TS highlights.scm only adds type-only captures; JS supplies keywords/functions/strings.
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        parent: .javascript,
        aliases: ["ts"]
    )

    public static let tsx = CodeLanguage(
        id: .tsx,
        tsName: "typescript",  // queries live under tree-sitter-typescript/
        displayName: "TSX",
        extensions: ["tsx"],
        lineComment: "//", rangeComment: ("/*", "*/"),
        additionalQueries: ["folds", "indents", "injections", "locals", "tags"],
        parent: .javascript
    )

    public static let verilog = CodeLanguage(
        id: .verilog, tsName: "verilog", displayName: "Verilog",
        extensions: ["v", "vh"],
        lineComment: "//", rangeComment: ("/*", "*/")
    )

    public static let yaml = CodeLanguage(
        id: .yaml, tsName: "yaml", displayName: "YAML",
        extensions: ["yaml", "yml"],
        lineComment: "#",
        additionalQueries: ["folds", "injections"]
    )

    public static let zig = CodeLanguage(
        id: .zig, tsName: "zig", displayName: "Zig",
        extensions: ["zig"],
        lineComment: "//",
        additionalQueries: ["folds", "injections"]
    )
}
