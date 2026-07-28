// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeEditorViewDemo",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "CodeEditorViewDemo",
            dependencies: [
                .product(name: "CodeEditorView", package: "CodeEditorView"),
            ],
            path: ".",
            exclude: ["Package.swift"]
        ),
    ]
)
