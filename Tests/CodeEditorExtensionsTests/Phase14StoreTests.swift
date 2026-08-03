import CodeEditorExtensionAPI
import Foundation
import Testing

@testable import CodeEditorExtensions

private enum P14Fixtures {
    static func makePackage(id: String, version: String, name: String? = nil, root: URL) throws -> URL {
        let dir = root.appendingPathComponent("\(id)-\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = """
            id = "\(id)"
            name = "\(name ?? id)"
            version = "\(version)"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT License".write(to: dir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        return dir
    }
}

@Suite("Phase 14 store atomicity")
struct Phase14StoreAtomicityTests {
    @Test func installUpdateRollbackPreservesVersions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.p14", version: "1.0.0", root: root)
        let plan1 = try await manager.install(from: v1)
        #expect(plan1.version.description == "1.0.0")
        let pkg1 = await manager.package(id: plan1.packageID)
        #expect(pkg1?.installPath.lastPathComponent == "1.0.0")

        let v2 = try P14Fixtures.makePackage(id: "com.example.p14", version: "1.1.0", name: "P14 v2", root: root)
        try await manager.update(id: plan1.packageID, from: v2)
        let pkg2 = await manager.package(id: plan1.packageID)
        #expect(pkg2?.currentVersion == "1.1.0")
        #expect(pkg2?.previousVersion == "1.0.0")
        #expect(pkg2?.plan.displayName == "P14 v2")
        // Old version dir remains
        let v1dir = root.appendingPathComponent(
            "packages/fca4e3ef7cc930b51cc38ebcc80ec24a3775cb22e15c5e45daa153839005c54b/1.0.0")
        #expect(FileManager.default.fileExists(atPath: v1dir.path))

        try await manager.rollback(id: plan1.packageID)
        let rolled = await manager.package(id: plan1.packageID)
        #expect(rolled?.currentVersion == "1.0.0")
        #expect(rolled?.installPath.lastPathComponent == "1.0.0")
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "packages/fca4e3ef7cc930b51cc38ebcc80ec24a3775cb22e15c5e45daa153839005c54b/1.1.0"
                ).path))
    }

    @Test func recoverRemovesStaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.rec", version: "1.0.0", root: root)
        _ = try await manager.install(from: v1)
        let staging = root.appendingPathComponent(
            "packages/b4974b0aeaa994102152fa3de8a64c3bbee6237f08fd1bed9e0c09019a280e65/.staging-dead")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "x".write(to: staging.appendingPathComponent("junk"), atomically: true, encoding: .utf8)
        await manager.recoverCorruptedState()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await manager.package(id: ExtensionID(rawValue: "com.example.rec")!) != nil)
    }

    @Test func userDataSurvivesUninstallWithoutPurge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.data", version: "1.0.0", root: root)
        let plan = try await manager.install(from: v1)
        let dataDir = await manager.userDataDir(id: plan.packageID)
        try "user-secret".write(to: dataDir.appendingPathComponent("prefs.txt"), atomically: true, encoding: .utf8)
        try await manager.uninstall(id: plan.packageID, purgeData: false)
        #expect(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("prefs.txt").path))
        try await manager.install(from: v1)
        try await manager.uninstall(id: plan.packageID, purgeData: true)
        #expect(!FileManager.default.fileExists(atPath: dataDir.path))
    }
}

@Suite("Phase 14 registry client")
struct Phase14RegistryClientTests {
    @Test func resolvesFromLocalIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14idx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try P14Fixtures.makePackage(id: "com.example.idx", version: "2.0.0", root: root)
        let index = ExtensionIndexDocument(packages: [
            ExtensionIndexEntry(
                id: "com.example.idx",
                name: "Idx",
                versions: [
                    ExtensionIndexVersion(version: "2.0.0", artifactPath: pkg.path, channel: "stable")
                ]
            )
        ])
        let indexURL = root.appendingPathComponent("index.json")
        try JSONEncoder().encode(index).write(to: indexURL)
        let client = ExtensionRegistryClient()
        let loaded = try await client.fetchIndex(from: indexURL)
        let ref = try client.resolve(index: loaded, id: ExtensionID(rawValue: "com.example.idx")!)
        #expect(ref.version == "2.0.0")
        #expect(ref.localPath?.path == pkg.path)
    }

    @Test func rejectsHTTPByDefault() async throws {
        let client = ExtensionRegistryClient()
        do {
            _ = try await client.fetchIndex(from: URL(string: "http://example.com/index.json")!)
            Issue.record("expected scheme reject")
        } catch ExtensionRegistryError.invalidScheme {
            // ok
        }
    }
}

@Suite("Phase 14 SBOM and telemetry")
struct Phase14SBOMTelemetryTests {
    @Test func generatesSBOMAndEnforcesLicense() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14sbom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = try P14Fixtures.makePackage(id: "com.example.sbom", version: "1.0.0", root: root)
        let plan = try ExtensionPackageLoader.load(directory: pkg, options: .init(computeDigest: false))
        let url = try PackageSBOM.write(packageRoot: pkg, plan: plan)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let doc = try PackageSBOM.load(packageRoot: pkg)
        #expect(!doc.files.isEmpty)
        try PackageSBOM.enforce(packageRoot: pkg, plan: plan, policy: .strict)
    }

    @Test func telemetryAppendsNDJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14tel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = StoreTelemetrySink(fileURL: root.appendingPathComponent("events.ndjson"))
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root, telemetry: sink)
        await manager.bootstrap()
        let pkg = try P14Fixtures.makePackage(id: "com.example.tel", version: "1.0.0", root: root)
        _ = try await manager.install(from: pkg)
        let events = try sink.readAll()
        #expect(events.contains { $0.event == "package.install" && $0.success })
    }
}

@Suite("Phase 14 revocation")
struct Phase14RevocationTests {
    @Test func revokedPackageCannotInstall() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let (authority, privateKey) = try RevocationListCrypto.generateAuthorityKeyPair(
            keyID: "p14-rev", issuer: "test")
        await manager.setRevocationAuthorities([authority])
        var revList = RevocationListDocument(
            entries: [
                RevocationEntry(packageID: "com.example.bad", version: "*", reason: "malware")
            ],
            sequence: 1,
            issuer: "test",
            keyID: "p14-rev",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try revList.sign(privateKeyRaw: privateKey, keyID: authority.keyID, issuer: authority.issuer)
        try await manager.setRevocationList(revList)
        let pkg = try P14Fixtures.makePackage(id: "com.example.bad", version: "1.0.0", root: root)
        do {
            _ = try await manager.install(from: pkg)
            Issue.record("expected revoke deny")
        } catch {
            // ok
        }
    }

    @Test func installedThenRevokedCannotActivate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14rev2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = StoreTelemetrySink(fileURL: root.appendingPathComponent("tel.ndjson"))
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root, telemetry: sink)
        await manager.bootstrap()
        let pkg = try P14Fixtures.makePackage(id: "com.example.later", version: "1.0.0", root: root)
        let plan = try await manager.install(from: pkg)
        try await manager.assertCanActivate(id: plan.packageID)
        let (authority, privateKey) = try RevocationListCrypto.generateAuthorityKeyPair(
            keyID: "p14-rev2", issuer: "test")
        await manager.setRevocationAuthorities([authority])
        var revList = RevocationListDocument(
            entries: [
                RevocationEntry(
                    packageID: "com.example.later", version: "1.0.0", reason: "post-install revoke")
            ],
            sequence: 1,
            issuer: "test",
            keyID: "p14-rev2",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try revList.sign(privateKeyRaw: privateKey, keyID: authority.keyID, issuer: authority.issuer)
        try await manager.setRevocationList(revList)
        do {
            try await manager.assertCanActivate(id: plan.packageID)
            Issue.record("expected post-install revoke deny")
        } catch {
            // ok
        }
        let events = try sink.readAll()
        #expect(events.contains { $0.event == "activation.denied" && $0.reason == "revoked" })
        #expect(FileManager.default.fileExists(atPath: (await manager.package(id: plan.packageID))!.installPath.path))
    }

    @Test func quarantineBlocksEnable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let pkg = try P14Fixtures.makePackage(id: "com.example.q", version: "1.0.0", root: root)
        let plan = try await manager.install(from: pkg)
        try await manager.quarantine(id: plan.packageID, reason: "policy")
        #expect(await manager.package(id: plan.packageID)?.quarantined == true)
        // Files remain
        #expect(FileManager.default.fileExists(atPath: (await manager.package(id: plan.packageID))!.installPath.path))
        do {
            try await manager.enable(id: plan.packageID)
            Issue.record("expected enable deny")
        } catch {
            // ok
        }
        do {
            try await manager.assertCanActivate(id: plan.packageID)
            Issue.record("expected activate deny")
        } catch {
            // ok
        }
    }
}

@Suite("Phase 14 interrupted install recover")
struct Phase14InterruptedInstallTests {
    @Test func stagingKillLeavesPreviousCurrentIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.int", version: "1.0.0", root: root)
        _ = try await manager.install(from: v1)
        let idRoot = root.appendingPathComponent(
            "packages/b6ead2069a52141168427c6ce579ca75e4b67524ecd46b634a87641d0bc86f81", isDirectory: true)
        let staging = idRoot.appendingPathComponent(".staging-killed", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "partial".write(to: staging.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        // Current still 1.0.0
        let current = try String(contentsOf: idRoot.appendingPathComponent("current"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(current == "1.0.0")
        await manager.recoverCorruptedState()
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(await manager.package(id: ExtensionID(rawValue: "com.example.int")!)?.currentVersion == "1.0.0")
    }

    @Test func recoverReconcilesFromFilesystemWhenStateMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.fs", version: "1.0.0", root: root)
        _ = try await manager.install(from: v1)
        // Simulate interrupted state write: wipe packages.json but leave version tree + current pointer
        try FileManager.default.removeItem(at: root.appendingPathComponent("state/packages.json"))
        let manager2 = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager2.bootstrap()
        #expect(await manager2.package(id: ExtensionID(rawValue: "com.example.fs")!) == nil)
        await manager2.recoverCorruptedState()
        #expect(await manager2.package(id: ExtensionID(rawValue: "com.example.fs")!)?.currentVersion == "1.0.0")
    }

    @Test func rollbackAfterRestartUsesPreviousPlanFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14rb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager.bootstrap()
        let v1 = try P14Fixtures.makePackage(id: "com.example.rb", version: "1.0.0", root: root)
        _ = try await manager.install(from: v1)
        let v2 = try P14Fixtures.makePackage(id: "com.example.rb", version: "2.0.0", name: "V2", root: root)
        try await manager.update(id: ExtensionID(rawValue: "com.example.rb")!, from: v2)
        // New process: load durable state + previous plan from disk
        let manager2 = ExtensionPackageManager.insecureForTests(installRoot: root)
        await manager2.bootstrap()
        #expect(await manager2.package(id: ExtensionID(rawValue: "com.example.rb")!)?.currentVersion == "2.0.0")
        #expect(await manager2.package(id: ExtensionID(rawValue: "com.example.rb")!)?.previousVersion == "1.0.0")
        try await manager2.rollback(id: ExtensionID(rawValue: "com.example.rb")!)
        #expect(await manager2.package(id: ExtensionID(rawValue: "com.example.rb")!)?.currentVersion == "1.0.0")
    }
}

@Suite("Phase 14 fixture registry")
struct Phase14FixtureRegistryTests {
    /// Prefer source-tree fixtures (full nested layout); Bundle.module may omit deep dirs on some SPM versions.
    private static var storeRoot: URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Store", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("index.json").path) {
            return source
        }
        if let url = Bundle.module.url(forResource: "Store", withExtension: nil) {
            return url
        }
        return source
    }

    @Test func indexFixtureResolvesSignedPackage() async throws {
        let indexURL = Self.storeRoot.appendingPathComponent("index.json")
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        let client = ExtensionRegistryClient()
        let index = try await client.fetchIndex(from: indexURL)
        let ref = try client.resolve(
            index: index,
            id: ExtensionID(rawValue: "com.example.signed")!,
            baseURL: Self.storeRoot
        )
        #expect(ref.version == "1.0.0")
        #expect(ref.localPath != nil)
        let local = ref.localPath!
        #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("extension.toml").path))
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14mat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let materialized = try await client.materialize(ref: ref, into: dest)
        #expect(FileManager.default.fileExists(atPath: materialized.appendingPathComponent("extension.toml").path))
    }
}
