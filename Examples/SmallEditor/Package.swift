// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmallEditor",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "SmallEditor",
            dependencies: [
                .product(name: "CodeEditorView", package: "CodeEditorView"),
                .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView"),
            ],
            path: "Sources"
        ),
    ]
)
