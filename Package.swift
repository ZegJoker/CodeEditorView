// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeEditorView",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CodeEditorCore", targets: ["CodeEditorCore"]),
        .library(name: "CodeEditorDocuments", targets: ["CodeEditorDocuments"]),
        .library(name: "CodeEditorCommands", targets: ["CodeEditorCommands"]),
        .library(name: "CodeEditorWorkspace", targets: ["CodeEditorWorkspace"]),
        .library(name: "CodeEditorWorkbench", targets: ["CodeEditorWorkbench"]),
        .library(name: "CodeEditorView", targets: ["CodeEditorView"]),
        .library(name: "CodeEditorLanguageSupport", targets: ["CodeEditorLanguageSupport"]),
        .library(name: "CodeEditorLanguageServices", targets: ["CodeEditorLanguageServices"]),
        .library(name: "CodeEditorTreeSitter", targets: ["CodeEditorTreeSitter"]),
        .library(name: "CodeEditorLanguageSwift", targets: ["CodeEditorLanguageSwift"]),
        .library(name: "CodeEditorLanguageJSON", targets: ["CodeEditorLanguageJSON"]),
        .library(name: "CodeEditorLanguages", targets: ["CodeEditorLanguages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.1.0")),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
    ],
    targets: [
        .target(
            name: "TreeSitterAgdaGrammar",
            path: "Grammars/src/agda",
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
            path: "Grammars/src/bash",
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
            path: "Grammars/src/c",
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
            path: "Grammars/src/c-sharp",
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
            path: "Grammars/src/cpp",
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
            path: "Grammars/src/css",
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
            path: "Grammars/src/dart",
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
            path: "Grammars/src/dockerfile",
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
            path: "Grammars/src/elixir",
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
            path: "Grammars/src/go",
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
            path: "Grammars/src/go-mod",
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
            path: "Grammars/src/haskell",
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
            path: "Grammars/src/html",
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
            path: "Grammars/src/java",
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
            path: "Grammars/src/javascript",
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
            path: "Grammars/src/jsdoc",
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
            path: "Grammars/src/json",
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
            path: "Grammars/src/julia",
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
            path: "Grammars/src/kotlin",
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
            path: "Grammars/src/lua",
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
            path: "Grammars/src/markdown",
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
            path: "Grammars/src/markdown-inline",
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
            path: "Grammars/src/objc",
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
            path: "Grammars/src/ocaml",
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
            path: "Grammars/src/perl",
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
            path: "Grammars/src/php",
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
            path: "Grammars/src/python",
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
            path: "Grammars/src/regex",
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
            path: "Grammars/src/ruby",
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
            path: "Grammars/src/rust",
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
            path: "Grammars/src/scala",
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
            path: "Grammars/src/sql",
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
            path: "Grammars/src/swift",
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
            path: "Grammars/src/toml",
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
            path: "Grammars/src/tsx",
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
            path: "Grammars/src/typescript",
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
            path: "Grammars/src/verilog",
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
            path: "Grammars/src/yaml",
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
            path: "Grammars/src/zig",
            sources: [
                "parser.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "CodeEditorCore",
            dependencies: [
                "TextStory",
            ]
        ),
        .target(
            name: "CodeEditorDocuments",
            dependencies: [
                "CodeEditorCore",
                "TextStory",
            ]
        ),
        .target(
            name: "CodeEditorCommands",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
            ]
        ),
        .target(
            name: "CodeEditorWorkspace",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
            ]
        ),
        .target(
            name: "CodeEditorWorkbench",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorWorkspace",
                "CodeEditorView",
                "CodeEditorLanguageSupport",
            ]
        ),
        .target(
            name: "CodeEditorLanguageSupport"
        ),
        .target(
            name: "CodeEditorLanguageServices",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorLanguageSupport",
            ]
        ),
        .target(
            name: "CodeEditorTreeSitter",
            dependencies: [
                "CodeEditorLanguageSupport",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            ]
        ),
        .target(
            name: "CodeEditorLanguageSwift",
            dependencies: [
                "CodeEditorLanguageSupport",
                "CodeEditorTreeSitter",
                "TreeSitterSwiftGrammar",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "CodeEditorLanguageJSON",
            dependencies: [
                "CodeEditorLanguageSupport",
                "CodeEditorTreeSitter",
                "TreeSitterJsonGrammar",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "CodeEditorLanguages",
            dependencies: [
                "CodeEditorLanguageSupport",
                "CodeEditorTreeSitter",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                "TreeSitterAgdaGrammar",
                "TreeSitterBashGrammar",
                "TreeSitterCGrammar",
                "TreeSitterCSharpGrammar",
                "TreeSitterCppGrammar",
                "TreeSitterCssGrammar",
                "TreeSitterDartGrammar",
                "TreeSitterDockerfileGrammar",
                "TreeSitterElixirGrammar",
                "TreeSitterGoGrammar",
                "TreeSitterGoModGrammar",
                "TreeSitterHaskellGrammar",
                "TreeSitterHtmlGrammar",
                "TreeSitterJavaGrammar",
                "TreeSitterJavascriptGrammar",
                "TreeSitterJsdocGrammar",
                "TreeSitterJsonGrammar",
                "TreeSitterJuliaGrammar",
                "TreeSitterKotlinGrammar",
                "TreeSitterLuaGrammar",
                "TreeSitterMarkdownGrammar",
                "TreeSitterMarkdownInlineGrammar",
                "TreeSitterObjcGrammar",
                "TreeSitterOcamlGrammar",
                "TreeSitterPerlGrammar",
                "TreeSitterPhpGrammar",
                "TreeSitterPythonGrammar",
                "TreeSitterRegexGrammar",
                "TreeSitterRubyGrammar",
                "TreeSitterRustGrammar",
                "TreeSitterScalaGrammar",
                "TreeSitterSqlGrammar",
                "TreeSitterSwiftGrammar",
                "TreeSitterTomlGrammar",
                "TreeSitterTsxGrammar",
                "TreeSitterTypescriptGrammar",
                "TreeSitterVerilogGrammar",
                "TreeSitterYamlGrammar",
                "TreeSitterZigGrammar"
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .target(
            name: "CodeEditorView",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorLanguageServices",
                "TextStory",
                "CodeEditorLanguageSupport",
                "CodeEditorTreeSitter",
                .product(name: "Collections", package: "swift-collections"),
            ]
        ),
        .testTarget(
            name: "CodeEditorCoreTests",
            dependencies: ["CodeEditorCore"]
        ),
        .testTarget(
            name: "CodeEditorDocumentsTests",
            dependencies: ["CodeEditorDocuments"]
        ),
        .testTarget(
            name: "CodeEditorCommandsTests",
            dependencies: ["CodeEditorCommands"]
        ),
        .testTarget(
            name: "CodeEditorWorkspaceTests",
            dependencies: ["CodeEditorWorkspace", "CodeEditorDocuments"]
        ),
        .testTarget(
            name: "CodeEditorWorkbenchTests",
            dependencies: ["CodeEditorWorkbench", "CodeEditorWorkspace", "CodeEditorDocuments"]
        ),
        .testTarget(
            name: "CodeEditorViewTests",
            dependencies: ["CodeEditorView", "CodeEditorLanguages", "CodeEditorDocuments", "CodeEditorCommands"]
        ),
        .testTarget(
            name: "CodeEditorLanguagesTests",
            dependencies: ["CodeEditorLanguages"]
        ),
        .testTarget(
            name: "CodeEditorLanguageSupportTests",
            dependencies: ["CodeEditorLanguageSupport"]
        ),
        .testTarget(
            name: "CodeEditorLanguageServicesTests",
            dependencies: ["CodeEditorLanguageServices"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
