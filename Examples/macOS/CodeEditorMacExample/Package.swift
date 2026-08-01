// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeEditorMacExample",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "CodeEditorMacExample", targets: ["CodeEditorMacExample"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "CodeEditorMacExample",
            dependencies: [
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CodeEditorMacExampleTests",
            dependencies: [
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
