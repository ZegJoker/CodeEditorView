// swift-tools-version: 6.0
// PKG-001: Grammar C sources live in Packages/CodeEditorGrammars (committed, deterministic).
// Root package declares zero Grammars/ paths so Core/View/Workbench resolve without generation.
// Language products depend on .product(..., package: "CodeEditorGrammars").
import PackageDescription
import Foundation

// Optional Ghostty link: export CODEEDITOR_GHOSTTY_LINKED=1 after ./scripts/build-ghostty.sh
let ghosttyLinked = ProcessInfo.processInfo.environment["CODEEDITOR_GHOSTTY_LINKED"] == "1"

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
        .library(name: "CodeEditorExtensionAPI", targets: ["CodeEditorExtensionAPI"]),
        .library(name: "CodeEditorExtensions", targets: ["CodeEditorExtensions"]),
        .executable(name: "codeeditor-extension", targets: ["CodeEditorExtensionCLI"]),
        .library(name: "CodeEditorExtensionHost", targets: ["CodeEditorExtensionHost"]),
        .library(name: "CodeEditorWasmEngine", targets: ["CodeEditorWasmEngine"]),
        .library(name: "CodeEditorWasmEngineWasmKit", targets: ["CodeEditorWasmEngineWasmKit"]),
        .library(name: "CodeEditorExtensionWasmGuest", targets: ["CodeEditorExtensionWasmGuest"]),
        .library(name: "CodeEditorExtensionProtocol", targets: ["CodeEditorExtensionProtocol"]),
        .library(name: "CodeEditorExtensionGuest", targets: ["CodeEditorExtensionGuest"]),
        // EXT-N20: ConformanceExtensionGuest is a fixture executable target only (not a public product).
        .library(name: "CodeEditorLSP", targets: ["CodeEditorLSP"]),
        .library(name: "CodeEditorDAP", targets: ["CodeEditorDAP"]),
        .library(name: "CodeEditorSearch", targets: ["CodeEditorSearch"]),
        .library(name: "CodeEditorTasks", targets: ["CodeEditorTasks"]),
        .library(name: "CodeEditorTerminal", targets: ["CodeEditorTerminal"]),
        .library(name: "CodeEditorTerminalGhostty", targets: ["CodeEditorTerminalGhostty"]),
        .library(name: "CodeEditorSourceControl", targets: ["CodeEditorSourceControl"]),
        .library(name: "CodeEditorTreeSitter", targets: ["CodeEditorTreeSitter"]),
        .library(name: "CodeEditorLanguageSwift", targets: ["CodeEditorLanguageSwift"]),
        .library(name: "CodeEditorLanguageJSON", targets: ["CodeEditorLanguageJSON"]),
        .library(name: "CodeEditorLanguages", targets: ["CodeEditorLanguages"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.1.0")),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", from: "0.1.5"),
        .package(path: "Packages/CodeEditorGrammars"),
    ],
    targets: [
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
                "CodeEditorTerminal",
                "CodeEditorTerminalGhostty",
                "CodeEditorSourceControl",
                "CodeEditorTasks",
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
            name: "CodeEditorExtensionAPI",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorLanguageSupport",
            ]
        ),
        .target(
            name: "CodeEditorExtensions",
            dependencies: [
                "CodeEditorExtensionAPI",
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorLanguageSupport",
                "CodeEditorLanguageServices",
            ]
        ),
        .executableTarget(
            name: "CodeEditorExtensionCLI",
            dependencies: [
                "CodeEditorExtensionAPI",
                "CodeEditorExtensions",
                "CodeEditorExtensionHost",
            ],
            path: "Sources/CodeEditorExtensionCLI"
        ),
        .target(
            name: "CodeEditorExtensionProtocol",
            dependencies: [
                "CodeEditorExtensionAPI",
            ]
        ),
        .target(
            name: "CodeEditorExtensionGuest",
            dependencies: [
                "CodeEditorExtensionProtocol",
                "CodeEditorExtensionAPI",
            ]
        ),
        .executableTarget(
            name: "ConformanceExtensionGuest",
            dependencies: [
                "CodeEditorExtensionGuest",
                "CodeEditorExtensionProtocol",
                "CodeEditorExtensionAPI",
                "CodeEditorLanguageServices",
                "CodeEditorCore",
                "CodeEditorDocuments",
            ],
            path: "Sources/ConformanceExtensionGuest"
        ),
        .target(
            name: "CodeEditorWasmEngine",
            dependencies: []
        ),
        // EXT-N20: LinkedGuest simulation is test-support only (not a public product).
        .target(
            name: "CodeEditorWasmEngineTestSupport",
            dependencies: [
                "CodeEditorWasmEngine",
                "CodeEditorExtensionWasmGuest",
            ],
            path: "Sources/CodeEditorWasmEngineTestSupport"
        ),
        .target(
            name: "CodeEditorWasmEngineWasmKit",
            dependencies: [
                "CodeEditorWasmEngine",
                .product(name: "WasmKit", package: "WasmKit"),
            ]
        ),
        .target(
            name: "CodeEditorExtensionWasmGuest",
            dependencies: [
                "CodeEditorExtensionAPI",
                "CodeEditorExtensionProtocol",
            ]
        ),
        .target(
            name: "CodeEditorExtensionHost",
            dependencies: [
                "CodeEditorExtensionProtocol",
                "CodeEditorExtensionGuest",
                "CodeEditorExtensionWasmGuest",
                "CodeEditorWasmEngine",
                "CodeEditorWasmEngineWasmKit",
                "CodeEditorExtensions",
                "CodeEditorExtensionAPI",
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorLanguageSupport",
                "CodeEditorLanguageServices",
                "CodeEditorWorkspace",
                "CodeEditorLSP",
                "CodeEditorDAP",
                "CodeEditorTasks",
                "CodeEditorTerminal",
            ]
        ),
        .target(
            name: "CodeEditorLSP",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorLanguageSupport",
                "CodeEditorLanguageServices",
                "CodeEditorWorkspace",
            ]
        ),
        .target(
            name: "CodeEditorDAP",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
            ]
        ),
        .target(
            name: "CodeEditorSearch",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorWorkspace",
            ]
        ),
        .target(
            name: "CodeEditorTasks",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorWorkspace",
                "CodeEditorLanguageServices",
            ]
        ),
        .target(
            name: "CodeEditorTerminal",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CGhosttyShim",
            ]
        ),
        .target(
            name: "CGhosttyShim",
            path: "Sources/CGhosttyShim",
            publicHeadersPath: "include",
            cSettings: ghosttyLinked ? [
                .headerSearchPath("include"),
                .define("CODEEDITOR_GHOSTTY_LINKED", to: "1"),
                // Textual include of libghostty-vt headers (avoid Vendor/ghostty modulemap GhosttyKit).
                .unsafeFlags([
                    "-fno-modules",
                    "-IVendor/ghostty/include",
                    "-IVendor/ghostty/zig-out/include",
                ]),
            ] : [
                .headerSearchPath("include"),
            ],
            linkerSettings: ghosttyLinked ? [
                .linkedLibrary("ghostty-vt", .when(platforms: [.macOS])),
                .linkedLibrary("util", .when(platforms: [.macOS])),
                .unsafeFlags(
                    [
                        "-LVendor/ghostty/zig-out/lib",
                        "-Xlinker", "-rpath",
                        "-Xlinker", "Vendor/ghostty/zig-out/lib",
                    ],
                    .when(platforms: [.macOS])
                ),
            ] : [
                .linkedLibrary("util", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CodeEditorTerminalGhostty",
            dependencies: [
                "CodeEditorTerminal",
                "CGhosttyShim",
                "CodeEditorDAP",
            ]
        ),
        .target(
            name: "CodeEditorSourceControl",
            dependencies: [
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorCommands",
                "CodeEditorWorkspace",
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
                .product(name: "TreeSitterSwiftGrammar", package: "CodeEditorGrammars"),
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
                .product(name: "TreeSitterJsonGrammar", package: "CodeEditorGrammars"),
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
                .product(name: "TreeSitterAgdaGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterBashGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterCGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterCSharpGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterCppGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterCssGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterDartGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterDockerfileGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterElixirGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterGoGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterGoModGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterHaskellGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterHtmlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterJavaGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterJavascriptGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterJsdocGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterJsonGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterJuliaGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterKotlinGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterLuaGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterMarkdownGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterMarkdownInlineGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterObjcGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterOcamlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterPerlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterPhpGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterPythonGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterRegexGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterRubyGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterRustGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterScalaGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterSqlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterSwiftGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterTomlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterTsxGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterTypescriptGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterVerilogGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterYamlGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterZigGrammar", package: "CodeEditorGrammars"),
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
            dependencies: ["CodeEditorCore"],
            resources: [
                .copy("../Fixtures/Profiles"),
            ]
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
            name: "CodeEditorTreeSitterTests",
            dependencies: [
                "CodeEditorTreeSitter",
                "CodeEditorLanguageSupport",
                // Real grammars for LANG-N02/N04/N05 ownership + fail-closed query compile.
                "CodeEditorLanguageJSON",
                "CodeEditorLanguageSwift",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterJsonGrammar", package: "CodeEditorGrammars"),
                .product(name: "TreeSitterSwiftGrammar", package: "CodeEditorGrammars"),
            ]
        ),
        .testTarget(
            name: "CodeEditorLanguagesTests",
            dependencies: [
                "CodeEditorLanguages",
                "CodeEditorLanguageSwift",
                "CodeEditorLanguageJSON",
                "CodeEditorTreeSitter",
            ]
        ),
        .testTarget(
            name: "CodeEditorLanguageSupportTests",
            dependencies: ["CodeEditorLanguageSupport"]
        ),
        .testTarget(
            name: "CodeEditorLanguageServicesTests",
            dependencies: ["CodeEditorLanguageServices"]
        ),
        .testTarget(
            name: "CodeEditorExtensionAPITests",
            dependencies: [
                "CodeEditorExtensionAPI",
                "CodeEditorExtensions",
            ],
            resources: [
                .copy("../Fixtures/Extensions"),
            ]
        ),
        .testTarget(
            name: "CodeEditorExtensionsTests",
            dependencies: [
                "CodeEditorExtensions",
                "CodeEditorExtensionAPI",
                "CodeEditorCommands",
                "CodeEditorLanguageServices",
                "CodeEditorLanguageSupport",
            ],
            resources: [
                .copy("../Fixtures/Store"),
            ]
        ),
        .testTarget(
            name: "CodeEditorLSPTests",
            dependencies: [
                "CodeEditorLSP",
                "CodeEditorLanguageServices",
                "CodeEditorDocuments",
                "CodeEditorWorkspace",
                "CodeEditorCore",
            ]
        ),
        .testTarget(
            name: "CodeEditorDAPTests",
            dependencies: [
                "CodeEditorDAP",
                "CodeEditorCore",
                "CodeEditorDocuments",
            ]
        ),
        .testTarget(
            name: "CodeEditorSearchTests",
            dependencies: ["CodeEditorSearch", "CodeEditorWorkspace", "CodeEditorDocuments"]
        ),
        .testTarget(
            name: "CodeEditorTasksTests",
            dependencies: ["CodeEditorTasks", "CodeEditorLanguageServices"]
        ),
        .testTarget(
            name: "CodeEditorTerminalTests",
            dependencies: [
                "CodeEditorTerminal",
                "CodeEditorTerminalGhostty",
                "CodeEditorCore",
                "CodeEditorDAP",
                "CGhosttyTestSpool",
            ]
        ),
        .target(
            name: "CGhosttyTestSpool",
            path: "Tests/Support/CGhosttyTestSpool",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "CodeEditorTerminalGhosttyTests",
            dependencies: [
                "CodeEditorTerminalGhostty",
                "CodeEditorTerminal",
                "CodeEditorCore",
                "CGhosttyTestSpool",
            ]
        ),
        .testTarget(
            name: "CodeEditorSourceControlTests",
            dependencies: [
                "CodeEditorSourceControl",
                "CodeEditorWorkspace",
                "CodeEditorDocuments",
                "CodeEditorCore",
            ]
        ),
        .testTarget(
            name: "CodeEditorExtensionProtocolTests",
            dependencies: [
                "CodeEditorExtensionProtocol",
                "CodeEditorExtensionAPI",
            ]
        ),
        .testTarget(
            name: "CodeEditorWasmEngineTests",
            dependencies: [
                "CodeEditorWasmEngine",
                "CodeEditorWasmEngineWasmKit",
                "CodeEditorWasmEngineTestSupport",
                "CodeEditorExtensionWasmGuest",
                "CodeEditorExtensionProtocol",
            ],
            resources: [.copy("../Fixtures/Wasm")]
        ),
        .testTarget(
            name: "CodeEditorExtensionHostTests",
            dependencies: [
                "CodeEditorExtensionHost",
                "CodeEditorExtensionProtocol",
                "CodeEditorExtensionGuest",
                "CodeEditorExtensionWasmGuest",
                "CodeEditorWasmEngine",
                "CodeEditorWasmEngineWasmKit",
                "CodeEditorWasmEngineTestSupport",
                "CodeEditorExtensions",
                "CodeEditorExtensionAPI",
                "CodeEditorLanguageServices",
                "CodeEditorCore",
                "CodeEditorDocuments",
                "CodeEditorLSP",
                "CodeEditorDAP",
                "CodeEditorTasks",
                "CodeEditorTerminal",
            ],
            resources: [.copy("../Fixtures/Wasm")]
        ),
        .testTarget(
            name: "ReleaseTruthTests",
            dependencies: []
        ),
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
