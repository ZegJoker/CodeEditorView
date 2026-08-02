// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LSPFixture",
    products: [
        .executable(name: "App", targets: ["App"])
    ],
    targets: [
        .executableTarget(name: "App")
    ]
)
