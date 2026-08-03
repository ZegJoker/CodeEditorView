import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation
import Testing

@testable import CodeEditorExtensionHost

@Suite("Phase 14 signing policy")
struct Phase14SigningTests {
    @Test func emptyKeyringRejectsSignedUnlessEscapeHatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        id = "com.example.sig"
        name = "Sig"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        license = "MIT"
        [activation]
        events = ["startup"]
        """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)

        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "k1")
        try ExtensionPackageSigner.sign(
            packageRoot: root,
            privateKeyRaw: kp.privateKeyRaw,
            keyID: kp.keyID,
            subject: "Pub"
        )

        // Strict empty keyring: fail closed
        #expect(throws: PackageSignatureError.unknownPublisher) {
            try ExtensionPackageVerifier.verify(packageRoot: root, policy: .strict)
        }

        // Explicit test escape hatch
        let trust = try ExtensionPackageVerifier.verify(
            packageRoot: root,
            policy: ExtensionTrustPolicy(allowUnknownSelfSigned: true)
        )
        #expect(trust == .trustedSigned)

        // Trusted keyring works
        let t2 = try ExtensionPackageVerifier.verify(
            packageRoot: root,
            policy: ExtensionTrustPolicy(trustedKeys: [
                ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Pub")
            ])
        )
        #expect(t2 == .trustedSigned)

        // Revoked key
        #expect(throws: PackageSignatureError.revokedKey("k1")) {
            try ExtensionPackageVerifier.verify(
                packageRoot: root,
                policy: ExtensionTrustPolicy(
                    trustedKeys: [
                        ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Pub")
                    ],
                    revokedKeyIDs: ["k1"]
                )
            )
        }
    }

    @Test func hostVerifierAdapter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14hv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        id = "com.example.hv"
        name = "HV"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let adapter = HostPackageVerifier(policy: .testing)
        let result = try adapter.verify(packageRoot: root)
        #expect(result.trustClass == .workspaceDev)
        #expect(result.quarantined == false)
    }

    @Test func trustPromptDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14tp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try """
        id = "com.example.tp"
        name = "TP"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: pkg.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            verifier: HostPackageVerifier(policy: .testing)
        )
        await manager.bootstrap()
        let plan = try await manager.install(from: pkg)
        let prompt = await manager.trustPromptIfNeeded(for: plan.packageID)
        #expect(prompt != nil)
        #expect(prompt?.trustClass == .workspaceDev)
        let items = await manager.trustStatusItems()
        #expect(items.contains { $0.packageID == plan.packageID.rawValue })
    }
}

@Suite("Phase 14 activation gate")
struct Phase14ActivationGateTests {
    private func makeServices() throws -> (ExtensionHostServices, CapabilityBroker) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14orch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let services = ExtensionHostServices()
        let broker = CapabilityBroker(
            config: .init(
                worktreeRoots: [tmp],
                storageRoot: tmp.appendingPathComponent("storage"),
                toolCacheRoot: tmp.appendingPathComponent("cache")
            ))
        return (services, broker)
    }

    @Test func revokedStorePackageCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14act-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pkgDir = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try """
        id = "com.example.act"
        name = "Act"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        license = "MIT"
        [activation]
        events = ["startup"]
        [runtime]
        kind = "data-only"
        """.write(to: pkgDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: pkgDir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)

        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            verifier: HostPackageVerifier(policy: .testing)
        )
        await manager.bootstrap()
        let plan = try await manager.install(from: pkgDir)
        let (authority, privateKey) = try RevocationListCrypto.generateAuthorityKeyPair(
            keyID: "p14-act", issuer: "test")
        await manager.setRevocationAuthorities([authority])
        var revList = RevocationListDocument(
            entries: [
                RevocationEntry(packageID: "com.example.act", version: "*", reason: "blocked")
            ],
            sequence: 1,
            issuer: "test",
            keyID: "p14-act",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try revList.sign(privateKeyRaw: privateKey, keyID: authority.keyID, issuer: authority.issuer)
        try await manager.setRevocationList(revList)

        let (services, broker) = try makeServices()
        let orch = ExtensionHostOrchestrator(
            services: services,
            broker: broker,
            policy: .testing
        )
        await orch.attachPackageManager(manager)
        let prepared = PreparedExtensionPackage(
            packageID: plan.packageID,
            displayName: plan.displayName,
            version: plan.version,
            manifest: plan.manifest,
            packageRoot: plan.packageRoot,
            trustClass: .workspaceDev,
            runtimePreference: .dataOnly
        )
        await orch.register(package: prepared)
        do {
            try await orch.start(id: plan.packageID)
            Issue.record("expected activation deny for revoked package")
        } catch {
            #expect(await orch.state(id: plan.packageID) == .quarantined)
        }
    }

    @Test func test_EXT_N15_liveRevokeStopsRunningDriver() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14live-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkgDir = root.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try """
            id = "com.example.live-rev"
            name = "LiveRev"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "data-only"
            """.write(to: pkgDir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: pkgDir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)

        let manager = ExtensionPackageManager.insecureForTests(
            installRoot: root,
            verifier: HostPackageVerifier(policy: .testing)
        )
        await manager.bootstrap()
        let plan = try await manager.install(from: pkgDir)

        let (authority, privateKey) = try RevocationListCrypto.generateAuthorityKeyPair(
            keyID: "p14-live", issuer: "test")
        await manager.setRevocationAuthorities([authority])

        let (services, broker) = try makeServices()
        let orch = ExtensionHostOrchestrator(
            services: services,
            broker: broker,
            policy: .testing
        )
        await orch.attachPackageManager(manager)
        let prepared = PreparedExtensionPackage(
            packageID: plan.packageID,
            displayName: plan.displayName,
            version: plan.version,
            manifest: plan.manifest,
            packageRoot: plan.packageRoot,
            trustClass: .workspaceDev,
            runtimePreference: .dataOnly
        )
        await orch.register(package: prepared)
        try await orch.start(id: plan.packageID)
        #expect(await orch.state(id: plan.packageID) == .active)

        var revList = RevocationListDocument(
            entries: [
                RevocationEntry(
                    packageID: "com.example.live-rev", version: "1.0.0", reason: "live-revoke")
            ],
            sequence: 1,
            issuer: "test",
            keyID: "p14-live",
            expiresAt: Date().addingTimeInterval(3600)
        )
        try revList.sign(privateKeyRaw: privateKey, keyID: authority.keyID, issuer: authority.issuer)
        try await manager.setRevocationList(revList)
        // EXT-N15: orchestrator terminator must stop the running driver immediately.
        #expect(await orch.state(id: plan.packageID) == .quarantined)
    }

    @Test func unsignedPackageRootDeniedUnderStrictPolicy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14strict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        id = "com.example.strict"
        name = "Strict"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        [activation]
        events = ["startup"]
        """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)

        let (services, broker) = try makeServices()
        let orch = ExtensionHostOrchestrator(
            services: services,
            broker: broker,
            policy: ExtensionExecutionPolicy(trust: .strict)
        )
        let prepared = PreparedExtensionPackage(
            packageID: ExtensionID(rawValue: "com.example.strict")!,
            displayName: "Strict",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.strict", displayName: "Strict"),
            packageRoot: root,
            trustClass: .untrusted,
            runtimePreference: .dataOnly
        )
        await orch.register(package: prepared)
        do {
            try await orch.start(id: prepared.packageID)
            Issue.record("expected strict deny for unsigned package root")
        } catch {
            #expect(await orch.state(id: prepared.packageID) == .quarantined)
        }
    }
}

@Suite("Phase 14 CLI surface")
struct Phase14CLISurfaceTests {
    @Test func packageSignVerifyRoundTripViaHostAPI() throws {
        // Mirrors CLI package/sign/verify commands without spawning the process.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p14cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        id = "com.example.cli"
        name = "CLI"
        version = "1.0.0"
        schema_version = 1
        api_version = "1.0"
        license = "MIT"
        [activation]
        events = ["startup"]
        """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        let plan = try ExtensionPackageLoader.load(directory: root, options: .init(computeDigest: false))
        _ = try PackageSBOM.write(packageRoot: root, plan: plan)
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "cli-k")
        // Sign after SBOM so checksums cover package evidence (CLI: package then sign).
        try ExtensionPackageSigner.sign(
            packageRoot: root,
            privateKeyRaw: kp.privateKeyRaw,
            keyID: kp.keyID,
            subject: "CLI Pub"
        )
        // Keyring lives outside the package tree (CLI authoring layout).
        let keyringDir = root.deletingLastPathComponent().appendingPathComponent(
            "p14-keyring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keyringDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: keyringDir) }
        var keyring = PublisherKeyring(keys: [
            ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "CLI Pub")
        ])
        let keyringURL = keyringDir.appendingPathComponent("keyring.json")
        try keyring.save(to: keyringURL)
        keyring = try PublisherKeyring.load(from: keyringURL)
        var policy = ExtensionTrustPolicy.strict
        policy.apply(keyring: keyring)
        let trust = try ExtensionPackageVerifier.verify(packageRoot: root, policy: policy)
        #expect(trust == .trustedSigned)
    }
}
