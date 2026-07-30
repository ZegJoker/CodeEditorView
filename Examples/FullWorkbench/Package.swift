// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FullWorkbench",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "FullWorkbench",
            dependencies: [
                .product(name: "CodeEditorWorkbench", package: "CodeEditorView"),
                .product(name: "CodeEditorWorkspace", package: "CodeEditorView"),
                .product(name: "CodeEditorDocuments", package: "CodeEditorView"),
                .product(name: "CodeEditorCommands", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageServices", package: "CodeEditorView"),
                .product(name: "CodeEditorSearch", package: "CodeEditorView"),
                .product(name: "CodeEditorTasks", package: "CodeEditorView"),
                .product(name: "CodeEditorSourceControl", package: "CodeEditorView"),
                .product(name: "CodeEditorTerminal", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ],
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
    ]
)
