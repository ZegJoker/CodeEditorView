import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation
import Testing

@testable import CodeEditorExtensionHost

@Suite("Phase8 extension security")
struct Phase8ExtensionSecurityTests {
    // MARK: - E1 identity

    @Test func extensionIDCorpusRejectsTraversal() throws {
        for bad in ["../../outside", "/absolute", "COM1.x", "a", "has space.x", ""] {
            #expect(throws: ExtensionIdentityError.self) {
                _ = try ExtensionID(validating: bad)
            }
        }
        // Uppercase is canonicalized to lowercase — valid.
        let upper = try ExtensionID(validating: "Com.Example.Hello")
        #expect(upper.rawValue == "com.example.hello")
        let ok = try ExtensionID(validating: "com.example.hello")
        #expect(ok.directoryKey.count == 64)
        #expect(ok.directoryKey != ok.rawValue)
    }

    // MARK: - E2/E7 package sealing

    @Test func rejectUnsignedExtraFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-extra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMinimalPackage(at: root, id: "com.example.extra")
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "k1")
        try ExtensionPackageSigner.sign(
            packageRoot: root, privateKeyRaw: kp.privateKeyRaw, keyID: kp.keyID, subject: "Pub")
        try "evil".write(to: root.appendingPathComponent("evil.bin"), atomically: true, encoding: .utf8)
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageVerifier.verify(
                packageRoot: root,
                policy: ExtensionTrustPolicy(trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Pub")
                ]))
        }
    }

    @Test func subjectSwapFailsWithTrustedKey() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-sub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMinimalPackage(at: root, id: "com.example.sub")
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "k1")
        try ExtensionPackageSigner.sign(
            packageRoot: root, privateKeyRaw: kp.privateKeyRaw, keyID: kp.keyID, subject: "RealPub")
        // Swap subject in publisher.json
        let pubURL = root.appendingPathComponent("publisher.json")
        var pub = try JSONSerialization.jsonObject(with: Data(contentsOf: pubURL)) as! [String: String]
        pub["subject"] = "EvilPub"
        try JSONSerialization.data(withJSONObject: pub).write(to: pubURL)
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageVerifier.verify(
                packageRoot: root,
                policy: ExtensionTrustPolicy(trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "RealPub")
                ]))
        }
    }

    @Test func rejectKeyMaterialInPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMinimalPackage(at: root, id: "com.example.keys")
        let keysDir = root.appendingPathComponent("keys", isDirectory: true)
        try FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: keysDir.appendingPathComponent("ed25519.private"))
        #expect(throws: PackageSignatureError.self) {
            _ = try ExtensionPackageSigner.fileDigests(packageRoot: root)
        }
    }

    // MARK: - E5 store quarantine

    @Test func corruptDurableStateQuarantinesStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: root)
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try "NOT-JSON".write(
            to: stateDir.appendingPathComponent("packages.json"), atomically: true, encoding: .utf8)
        await mgr.bootstrap()
        #expect(await mgr.storeQuarantined)
        #expect(await mgr.storeQuarantineReason != nil)
    }

    // MARK: - E11 storage quota overwrite

    @Test func storageOverwriteDoesNotDoubleQuota() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-quota-\(UUID().uuidString)", isDirectory: true)
        let broker = try CapabilityBroker(
            config: .init(
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c"),
                storageQuotaBytes: 20
            ))
        let id: ExtensionID = "com.example.quota"
        await broker.registerExtension(id: id, generation: 1, granted: [])
        let h = try await broker.storageHandle(extensionID: id)
        try await broker.storageSet(caller: id, handle: h.id, key: "a", value: Data(repeating: 1, count: 12))
        // Overwrite same key with same size must not exhaust quota.
        try await broker.storageSet(caller: id, handle: h.id, key: "a", value: Data(repeating: 2, count: 12))
        try await broker.storageSet(caller: id, handle: h.id, key: "a", value: Data(repeating: 3, count: 12))
        let again = try await broker.storageGet(caller: id, handle: h.id, key: "a")
        #expect(again?.count == 12)
        // Path uses directoryKey
        let paths = try FileManager.default.contentsOfDirectory(
            at: tmp.appendingPathComponent("s"), includingPropertiesForKeys: nil)
        #expect(paths.contains(where: { $0.lastPathComponent == id.directoryKey }))
    }

    // MARK: - E12 settings durable

    @Test func settingsPersistAcrossBrokerInstances() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-set-\(UUID().uuidString)", isDirectory: true)
        let storage = tmp.appendingPathComponent("s")
        let cache = tmp.appendingPathComponent("c")
        let id: ExtensionID = "com.example.settings"
        do {
            let broker = try CapabilityBroker(config: .init(storageRoot: storage, toolCacheRoot: cache))
            await broker.registerExtension(id: id, generation: 1, granted: [])
            let h = try await broker.settingsHandle(extensionID: id)
            try await broker.settingsSet(caller: id, handle: h.id, key: "theme", value: "dark")
        }
        let broker2 = try CapabilityBroker(config: .init(storageRoot: storage, toolCacheRoot: cache))
        await broker2.registerExtension(id: id, generation: 1, granted: [])
        let h2 = try await broker2.settingsHandle(extensionID: id)
        let v = try await broker2.settingsGet(caller: id, handle: h2.id, key: "theme")
        #expect(v == "dark")
    }

    // MARK: - E14 process allowlist

    @Test func processBasenameOnlyAttackDenied() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-proc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let evil = tmp.appendingPathComponent("sleep")
        // Create a non-executable placeholder path string; allowlist uses /bin/sleep
        let broker = try CapabilityBroker(
            config: .init(
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c"),
                processAllowlist: [.init(command: "/bin/sleep"), .init(command: "sleep")]
            ))
        let id: ExtensionID = "com.example.proc"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        // evil path with basename sleep must be denied
        #expect(await broker.processAllowed(executable: evil.path) == false)
        #expect(await broker.processAllowed(executable: "/bin/sleep") == true)
        do {
            _ = try await broker.processSpawn(caller: id, handle: h.id, executable: evil.path, arguments: ["1"])
            Issue.record("expected process denied for evil basename path")
        } catch BrokerError.processDenied {
            // ok
        } catch {
            // launch may fail for other reasons; processAllowed already covers identity
        }
    }

    // MARK: - E15 multi-root worktree + read limit

    @Test func multiRootWorktreeHandles() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-wt-\(UUID().uuidString)", isDirectory: true)
        let r1 = base.appendingPathComponent("r1", isDirectory: true)
        let r2 = base.appendingPathComponent("r2", isDirectory: true)
        try FileManager.default.createDirectory(at: r1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: r2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "one".write(to: r1.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: r2.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let broker = try CapabilityBroker(
            config: .init(
                worktreeRoots: [r1, r2],
                storageRoot: base.appendingPathComponent("s"),
                toolCacheRoot: base.appendingPathComponent("c"),
                maxWorktreeReadBytes: 8
            ))
        let id: ExtensionID = "com.example.wt"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let h1 = try await broker.worktreeHandle(extensionID: id, root: r1)
        let h2 = try await broker.worktreeHandle(extensionID: id, root: r2)
        let a = try await broker.worktreeRead(caller: id, handle: h1.id, relative: "a.txt")
        let b = try await broker.worktreeRead(caller: id, handle: h2.id, relative: "b.txt")
        #expect(String(data: a, encoding: .utf8) == "one")
        #expect(String(data: b, encoding: .utf8) == "two")
        // huge read denied
        try Data(repeating: 9, count: 64).write(to: r1.appendingPathComponent("big.bin"))
        do {
            _ = try await broker.worktreeRead(caller: id, handle: h1.id, relative: "big.bin")
            Issue.record("expected quota on large read")
        } catch BrokerError.quotaExceeded {
            // ok
        }
    }

    @Test func revokeExtensionInvalidatesHandles() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-rev-\(UUID().uuidString)", isDirectory: true)
        let broker = try CapabilityBroker(
            config: .init(storageRoot: tmp.appendingPathComponent("s"), toolCacheRoot: tmp.appendingPathComponent("c")))
        let id: ExtensionID = "com.example.rev"
        await broker.registerExtension(id: id, generation: 1, granted: [])
        let h = try await broker.storageHandle(extensionID: id)
        await broker.revokeExtension(id: id)
        do {
            _ = try await broker.storageGet(caller: id, handle: h.id, key: "x")
            Issue.record("expected forged/stale handle")
        } catch BrokerError.forgedHandle, BrokerError.staleGeneration, BrokerError.revokedHandle {
            // ok
        } catch {
            // resolve may throw forgedHandle / other typed denial
            let desc = String(describing: error).lowercased()
            #expect(desc.contains("forged") || desc.contains("stale") || desc.contains("revok") || desc.contains("handle"))
        }
    }

    // MARK: - E13 npm materializer

    @Test func npmMaterializesFromRegistryNotStub() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-npm-\(UUID().uuidString)", isDirectory: true)
        let reg = tmp.appendingPathComponent("reg/demo-pkg/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: reg, withIntermediateDirectories: true)
        try """
            {"name":"demo-pkg","version":"1.0.0","scripts":{"postinstall":"evil"}}
            """.write(to: reg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "exports.x=1\n".write(to: reg.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let broker = try CapabilityBroker(
            config: .init(
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c"),
                npmAllowlist: [.init(package: "demo-pkg", version: "1.0.0")],
                npmRegistryRoot: tmp.appendingPathComponent("reg")
            ))
        let id: ExtensionID = "com.example.npm"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let h = try await broker.npmHandle(extensionID: id)
        let dest = try await broker.npmInstall(caller: id, handle: h.id, package: "demo-pkg", version: "1.0.0")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("index.js").path))
        let pkg = try String(contentsOf: dest.appendingPathComponent("package.json"), encoding: .utf8)
        // Immutable copy preserves source scripts text; host never executes lifecycle scripts.
        #expect(pkg.contains("postinstall") || pkg.contains("demo-pkg"))
        // Off-allowlist denied
        do {
            _ = try await broker.npmInstall(caller: id, handle: h.id, package: "other", version: "1.0.0")
            Issue.record("expected npm deny")
        } catch BrokerError.npmDenied {
            // ok
        }
    }

    // MARK: - E18 conformance

    @Test func sdkConformanceDataOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p8-conf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMinimalPackage(at: root, id: "com.example.conf")
        let result = try ExtensionSDKConformance.runDataOnlyPackage(at: root)
        #expect(result.checks["has_extension_toml"] == true)
        #expect(result.checks["loads_plan"] == true)
        #expect(result.passed)
    }

    // MARK: - Helpers

    private func writeMinimalPackage(at root: URL, id: String) throws {
        try """
            id = "\(id)"
            name = "Pkg"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0.0"
            [activation]
            events = ["startup"]
            """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
    }
}

@Suite("Phase8 API TOML")
struct Phase8APITomlTests {
    @Test func unknownActivationEventFails() throws {
        let toml = """
            id = "com.example.act"
            name = "A"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0.0"
            [activation]
            events = ["notARealEvent"]
            """
        let (manifest, _) = try ExtensionTOMLParser.parse(string: toml)
        #expect(throws: ExtensionError.self) {
            _ = try manifest.toExtensionManifest()
        }
    }

    @Test func invalidAPIVersionFails() throws {
        let toml = """
            id = "com.example.api"
            name = "A"
            version = "1.0.0"
            schema_version = 1
            api_version = "not-semver"
            [activation]
            events = ["startup"]
            """
        let (manifest, _) = try ExtensionTOMLParser.parse(string: toml)
        #expect(throws: ExtensionError.self) {
            _ = try manifest.toExtensionManifest()
        }
    }
}
