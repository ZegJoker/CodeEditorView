// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeEditoriOSExample",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "CodeEditoriOSExample", targets: ["CodeEditoriOSExample"]),
    ],
    dependencies: [
        .package(path: "../../.."),
    ],
    targets: [
        .target(
            name: "CodeEditoriOSExample",
            dependencies: [
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CodeEditoriOSExampleTests",
            dependencies: [
                "CodeEditoriOSExample",
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
