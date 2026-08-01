// swift-tools-version: 6.0
// PKG-001: Deterministic committed Tree-sitter grammar C sources.
// Regenerated/updated via ../../scripts/update-grammars.sh (maintainer tool).
import PackageDescription

let package = Package(
    name: "CodeEditorGrammars",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "TreeSitterAgdaGrammar", targets: ["TreeSitterAgdaGrammar"]),
        .library(name: "TreeSitterBashGrammar", targets: ["TreeSitterBashGrammar"]),
        .library(name: "TreeSitterCGrammar", targets: ["TreeSitterCGrammar"]),
        .library(name: "TreeSitterCSharpGrammar", targets: ["TreeSitterCSharpGrammar"]),
        .library(name: "TreeSitterCppGrammar", targets: ["TreeSitterCppGrammar"]),
        .library(name: "TreeSitterCssGrammar", targets: ["TreeSitterCssGrammar"]),
        .library(name: "TreeSitterDartGrammar", targets: ["TreeSitterDartGrammar"]),
        .library(name: "TreeSitterDockerfileGrammar", targets: ["TreeSitterDockerfileGrammar"]),
        .library(name: "TreeSitterElixirGrammar", targets: ["TreeSitterElixirGrammar"]),
        .library(name: "TreeSitterGoGrammar", targets: ["TreeSitterGoGrammar"]),
        .library(name: "TreeSitterGoModGrammar", targets: ["TreeSitterGoModGrammar"]),
        .library(name: "TreeSitterHaskellGrammar", targets: ["TreeSitterHaskellGrammar"]),
        .library(name: "TreeSitterHtmlGrammar", targets: ["TreeSitterHtmlGrammar"]),
        .library(name: "TreeSitterJavaGrammar", targets: ["TreeSitterJavaGrammar"]),
        .library(name: "TreeSitterJavascriptGrammar", targets: ["TreeSitterJavascriptGrammar"]),
        .library(name: "TreeSitterJsdocGrammar", targets: ["TreeSitterJsdocGrammar"]),
        .library(name: "TreeSitterJsonGrammar", targets: ["TreeSitterJsonGrammar"]),
        .library(name: "TreeSitterJuliaGrammar", targets: ["TreeSitterJuliaGrammar"]),
        .library(name: "TreeSitterKotlinGrammar", targets: ["TreeSitterKotlinGrammar"]),
        .library(name: "TreeSitterLuaGrammar", targets: ["TreeSitterLuaGrammar"]),
        .library(name: "TreeSitterMarkdownGrammar", targets: ["TreeSitterMarkdownGrammar"]),
        .library(name: "TreeSitterMarkdownInlineGrammar", targets: ["TreeSitterMarkdownInlineGrammar"]),
        .library(name: "TreeSitterObjcGrammar", targets: ["TreeSitterObjcGrammar"]),
        .library(name: "TreeSitterOcamlGrammar", targets: ["TreeSitterOcamlGrammar"]),
        .library(name: "TreeSitterPerlGrammar", targets: ["TreeSitterPerlGrammar"]),
        .library(name: "TreeSitterPhpGrammar", targets: ["TreeSitterPhpGrammar"]),
        .library(name: "TreeSitterPythonGrammar", targets: ["TreeSitterPythonGrammar"]),
        .library(name: "TreeSitterRegexGrammar", targets: ["TreeSitterRegexGrammar"]),
        .library(name: "TreeSitterRubyGrammar", targets: ["TreeSitterRubyGrammar"]),
        .library(name: "TreeSitterRustGrammar", targets: ["TreeSitterRustGrammar"]),
        .library(name: "TreeSitterScalaGrammar", targets: ["TreeSitterScalaGrammar"]),
        .library(name: "TreeSitterSqlGrammar", targets: ["TreeSitterSqlGrammar"]),
        .library(name: "TreeSitterSwiftGrammar", targets: ["TreeSitterSwiftGrammar"]),
        .library(name: "TreeSitterTomlGrammar", targets: ["TreeSitterTomlGrammar"]),
        .library(name: "TreeSitterTsxGrammar", targets: ["TreeSitterTsxGrammar"]),
        .library(name: "TreeSitterTypescriptGrammar", targets: ["TreeSitterTypescriptGrammar"]),
        .library(name: "TreeSitterVerilogGrammar", targets: ["TreeSitterVerilogGrammar"]),
        .library(name: "TreeSitterYamlGrammar", targets: ["TreeSitterYamlGrammar"]),
        .library(name: "TreeSitterZigGrammar", targets: ["TreeSitterZigGrammar"]),
    ],
    targets: [
        .target(
            name: "TreeSitterAgdaGrammar",
            path: "Sources/agda",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterBashGrammar",
            path: "Sources/bash",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterCGrammar",
            path: "Sources/c",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterCSharpGrammar",
            path: "Sources/c-sharp",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterCppGrammar",
            path: "Sources/cpp",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterCssGrammar",
            path: "Sources/css",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterDartGrammar",
            path: "Sources/dart",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterDockerfileGrammar",
            path: "Sources/dockerfile",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterElixirGrammar",
            path: "Sources/elixir",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterGoGrammar",
            path: "Sources/go",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterGoModGrammar",
            path: "Sources/go-mod",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterHaskellGrammar",
            path: "Sources/haskell",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterHtmlGrammar",
            path: "Sources/html",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterJavaGrammar",
            path: "Sources/java",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterJavascriptGrammar",
            path: "Sources/javascript",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterJsdocGrammar",
            path: "Sources/jsdoc",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterJsonGrammar",
            path: "Sources/json",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterJuliaGrammar",
            path: "Sources/julia",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterKotlinGrammar",
            path: "Sources/kotlin",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterLuaGrammar",
            path: "Sources/lua",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterMarkdownGrammar",
            path: "Sources/markdown",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterMarkdownInlineGrammar",
            path: "Sources/markdown-inline",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterObjcGrammar",
            path: "Sources/objc",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterOcamlGrammar",
            path: "Sources/ocaml",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterPerlGrammar",
            path: "Sources/perl",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterPhpGrammar",
            path: "Sources/php",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterPythonGrammar",
            path: "Sources/python",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterRegexGrammar",
            path: "Sources/regex",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterRubyGrammar",
            path: "Sources/ruby",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterRustGrammar",
            path: "Sources/rust",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterScalaGrammar",
            path: "Sources/scala",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterSqlGrammar",
            path: "Sources/sql",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterSwiftGrammar",
            path: "Sources/swift",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterTomlGrammar",
            path: "Sources/toml",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterTsxGrammar",
            path: "Sources/tsx",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterTypescriptGrammar",
            path: "Sources/typescript",
            sources: [
                "parser.c",
                "scanner.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterVerilogGrammar",
            path: "Sources/verilog",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterYamlGrammar",
            path: "Sources/yaml",
            sources: [
                "parser.c",
                "scanner.c",
                "schema.core.c",
                "schema.json.c",
                "schema.legacy.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "TreeSitterZigGrammar",
            path: "Sources/zig",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        )
    ],
    cLanguageStandard: .c11
)
