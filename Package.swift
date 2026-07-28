// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeEditorView",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "CodeEditorView",
            targets: ["CodeEditorView"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.1.0")),
    ],
    targets: [
        .target(
            name: "CodeEditorView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
            ]
        ),
        .testTarget(
            name: "CodeEditorViewTests",
            dependencies: ["CodeEditorView"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
