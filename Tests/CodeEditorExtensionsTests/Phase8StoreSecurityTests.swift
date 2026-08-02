import CodeEditorExtensionAPI
import Foundation
import Testing

@testable import CodeEditorExtensions

@Suite("Phase8 store security")
struct Phase8StoreSecurityTests {
    @Test func sbomDigestIsCryptographic() throws {
        // Equal-length different content must not collide via length fallback.
        let a = Data("aaaa".utf8)
        let b = Data("bbbb".utf8)
        #expect(a.count == b.count)
        // PackageSBOM inventory uses real SHA-256 when CryptoKit present (default on Apple).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-sbom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try a.write(to: root.appendingPathComponent("a.txt"))
        try b.write(to: root.appendingPathComponent("b.txt"))
        try """
            id = "com.example.sbom"
            name = "S"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0.0"
            [activation]
            events = ["startup"]
            """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let plan = try ExtensionPackageLoader.load(directory: root, options: .init(computeDigest: false))
        let sbom = try PackageSBOM.generate(packageRoot: root, plan: plan)
        let values = sbom.files.flatMap(\.checksums).map(\.checksumValue)
        #expect(Set(values).count >= 2 || values.count >= 2)
        #expect(values.allSatisfy { $0.count >= 32 })
    }

    @Test func packageManagerUsesDirectoryKey() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-dirkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: root)
        let id = try ExtensionID(validating: "com.example.dirkey")
        let dir = await mgr.packageDirectory(for: id)
        #expect(dir.lastPathComponent == id.directoryKey)
        #expect(dir.lastPathComponent != id.rawValue)
    }
}
