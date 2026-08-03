import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation
import Testing

@testable import CodeEditorExtensionHost

@Suite("Phase 16 security")
struct Phase16SecurityTests {
    @Test func masDeniesNativeAndDownloadableWasm() throws {
        let native = PreparedExtensionPackage(
            packageID: "com.example.sec.n",
            displayName: "N",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.sec.n", displayName: "N"),
            nativeExecutable: URL(fileURLWithPath: "/tmp/helper"),
            trustClass: .trustedSigned,
            runtimePreference: .nativeProcess,
            origin: .installed
        )
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: native, policy: .shipping(.macAppStore))
        }
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: native, policy: .shipping(.iOS))
        }

        let wasm = PreparedExtensionPackage(
            packageID: "com.example.sec.w",
            displayName: "W",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.sec.w", displayName: "W"),
            wasmModuleData: Data([0x00, 0x61, 0x73, 0x6D]),
            trustClass: .trustedSigned,
            runtimePreference: .swiftWasm,
            origin: .installed
        )
        #expect(throws: RuntimeSelectionError.self) {
            try RuntimeSelector.select(package: wasm, policy: .shipping(.iOS))
        }
    }

    @Test func emptyKeyringRejectsSignedPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        id = "com.example.sec.sig"
        name = "Sig"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        license = "MIT"
        [activation]
        events = ["startup"]
        """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "sec")
        try ExtensionPackageSigner.sign(
            packageRoot: root,
            privateKeyRaw: kp.privateKeyRaw,
            keyID: kp.keyID,
            subject: "Sec"
        )
        #expect(throws: PackageSignatureError.unknownPublisher) {
            try ExtensionPackageVerifier.verify(packageRoot: root, policy: .strict)
        }
    }

    @Test func nativeHelperPolicyDeniesUntrusted() {
        let d = NativeHelperLaunchPolicy.evaluate(
            trustClass: .untrusted,
            origin: .installed,
            policy: .shipping(.directMacOS)
        )
        #expect(d.allowed == false)
    }
}

@Suite("Phase 16 conformance glue")
struct Phase16ConformanceTests {
    @Test func builtInConformanceMethodsPresent() async throws {
        let services = ExtensionHostServices()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16conf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try CapabilityBroker(
            config: .init(
                worktreeRoots: [tmp],
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c")
            ))
        let orch = ExtensionHostOrchestrator(
            services: services,
            broker: broker,
            policy: .testing
        )
        // Minimal data-only package activation path (always claimed)
        let pkg = PreparedExtensionPackage(
            packageID: "com.example.conf.data",
            displayName: "Data",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.conf.data", displayName: "Data"),
            trustClass: .workspaceDev,
            runtimePreference: .dataOnly,
            origin: .bundled
        )
        await orch.register(package: pkg)
        try await orch.start(id: pkg.packageID)
        #expect(await orch.state(id: pkg.packageID) == .active)
        await orch.stop(id: pkg.packageID)
    }

    @Test func hostProfilesExposeDistinctAllowedRuntimes() {
        let ios = ExtensionHostProfile.shipping(.iOS)
        #expect(!ios.allowedRuntimes.contains(.nativeProcess))
        #expect(ios.allowedRuntimes.contains(.dataOnly))
        #expect(ios.remoteFallbackAvailable)

        let direct = ExtensionHostProfile.shipping(.directMacOS)
        #expect(direct.allowedRuntimes.contains(.nativeProcess))
        #expect(direct.allowedRuntimes.contains(.swiftWasm))
    }
}

@Suite("Phase 16 orchestrator soak")
struct Phase16OrchestratorSoakTests {
    @Test func dataOnlyStartStopLoop() async throws {
        let iterations = 25
        let services = ExtensionHostServices()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p16os-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let broker = try CapabilityBroker(
            config: .init(
                worktreeRoots: [tmp],
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c")
            ))
        let orch = ExtensionHostOrchestrator(services: services, broker: broker, policy: .testing)
        let pkg = PreparedExtensionPackage(
            packageID: "com.example.soak.data",
            displayName: "Soak",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.soak.data", displayName: "Soak"),
            trustClass: .workspaceDev,
            runtimePreference: .dataOnly,
            origin: .bundled
        )
        await orch.register(package: pkg)
        var failures = 0
        for _ in 0..<iterations {
            do {
                try await orch.start(id: pkg.packageID)
                await orch.stop(id: pkg.packageID)
            } catch {
                failures += 1
            }
        }
        #expect(failures == 0)
        #expect(iterations >= 20)
    }
}
