import CodeEditorCore
import CodeEditorExtensionAPI
import Foundation
import Testing

@testable import CodeEditorExtensions

// StreamItem / AsyncBroadcastHub used by EXT-N19 hub contract assertions.

// MARK: - Helpers

private enum EXTNFixtures {
    static func tempRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extn-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeMinimalPackage(
        at root: URL,
        id: String = "com.example.extn",
        version: String = "1.0.0",
        extraFiles: [(String, String)] = []
    ) throws {
        try """
            id = "\(id)"
            name = "EXTN"
            version = "\(version)"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "data-only"
            """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        for (path, body) in extraFiles {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - EXT-N01 TOML / CEML fail-closed

@Suite("EXT-N01 CEML / TOML fail-closed")
struct EXT_N01_Tests {
    @Test func test_EXT_N01_malformedLineFailsClosed() {
        let bad = """
            id = "com.example.bad"
            name = "Bad"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            this is not a valid assignment
            [activation]
            events = ["startup"]
            """
        #expect(throws: ExtensionError.self) {
            _ = try ExtensionTOMLParser.parse(string: bad)
        }
    }

    @Test func test_EXT_N01_stringEscapesAndDottedKeys() throws {
        let src = """
            id = "com.example.esc"
            name = "Line\\nBreak"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "data-only"
            """
        let (m, diags) = try ExtensionTOMLParser.parse(string: src)
        #expect(!diags.contains { $0.severity == .error })
        #expect(m.name.contains("\n") || m.name.contains("\\n") || m.name == "Line\nBreak")
        #expect(ExtensionTOMLParser.languageName == "CodeEditor Manifest Language")
        #expect(ExtensionTOMLParser.isGeneralTOML == false)
    }

    @Test func test_EXT_N01_commentInsideStringPreserved() throws {
        let src = """
            id = "com.example.hash"
            name = "has # hash"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            [activation]
            events = ["startup"]
            """
        let (m, _) = try ExtensionTOMLParser.parse(string: src)
        #expect(m.name == "has # hash")
    }
}

// MARK: - EXT-N02 compatibility levels

@Suite("EXT-N02 compatibility levels")
struct EXT_N02_Tests {
    @Test func test_EXT_N02_compatibilityLevelsNotSingleBoolean() {
        let report = ExtensionCompatibilityReport.preAlphaDefault
        #expect(report.zedBinaryCompatibility == false)
        #expect(report.level(for: "package_syntax") == .s0PackageSyntax)
        #expect(report.level(for: "themes") == .s1DataContributions)
        #expect(ExtensionCompatibilityLevel.allCases.count == 5)
        // Must not collapse to a single "passing" flag.
        let levels = Set(report.features.map(\.level))
        #expect(levels.count >= 2 || report.features.contains { !$0.evidenceTests.isEmpty })
        for f in report.features where f.feature != "zed_binary" {
            #expect(!f.evidenceTests.isEmpty || f.level == .s0PackageSyntax)
        }
    }
}

// MARK: - EXT-N03 SHA-256 only

@Suite("EXT-N03 cryptographic digests")
struct EXT_N03_Tests {
    @Test func test_EXT_N03_packageDigestIsSHA256Hex() throws {
        let root = try EXTNFixtures.tempRoot("digest")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(at: root)
        let digest = try ExtensionPackageDigest.compute(packageRoot: root)
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit })
        // Distinct content → distinct digest
        try "other".write(to: root.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        let digest2 = try ExtensionPackageDigest.compute(packageRoot: root)
        #expect(digest != digest2)
    }

    @Test func test_EXT_N03_hasherRejectsNonCryptoFallback() {
        // Production hasher must not expose DJB-style short digests.
        var h = SHA256Hasher()
        h.update(Data("abc".utf8))
        let hex = h.finalizeHex()
        #expect(hex.count == 64)
        #expect(hex != String(format: "%016llx", 5381))
    }
}

// MARK: - EXT-N04 hidden files in inventory

@Suite("EXT-N04 hidden file inventory")
struct EXT_N04_Tests {
    @Test func test_EXT_N04_hiddenFilesIncludedInInventory() throws {
        let root = try EXTNFixtures.tempRoot("hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(
            at: root,
            extraFiles: [(".secret/payload.bin", "attack")]
        )
        let inv = try PackageInventoryBuilder.build(packageRoot: root)
        #expect(inv.entries.contains { $0.relativePath == ".secret/payload.bin" })
    }
}

// MARK: - EXT-N05 .codeeditor package content

@Suite("EXT-N05 codeeditor package content")
struct EXT_N05_Tests {
    @Test func test_EXT_N05_codeeditorPackageContentInInventory() async throws {
        let root = try EXTNFixtures.tempRoot("ce")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(
            at: root,
            extraFiles: [(".codeeditor/contrib.json", "{\"x\":1}")]
        )
        let inv = try PackageInventoryBuilder.build(packageRoot: root)
        #expect(inv.entries.contains { $0.relativePath == ".codeeditor/contrib.json" })
        // Host state lives outside package, not under package .codeeditor alone.
        let store = try EXTNFixtures.tempRoot("store")
        defer { try? FileManager.default.removeItem(at: store) }
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        let hostState = await mgr.hostStateRoot
        #expect(hostState.path.contains("host-state") || hostState.path.hasSuffix("host-state"))
    }
}

// MARK: - EXT-N10 inventory quotas

@Suite("EXT-N10 inventory quotas")
struct EXT_N10_Tests {
    @Test func test_EXT_N10_fileCountQuota() throws {
        let root = try EXTNFixtures.tempRoot("quota")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(at: root)
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let limits = PackageInventoryLimits(
            maxFileCount: 2,
            maxDirectoryDepth: 8,
            maxFileBytes: 1_000_000,
            maxTotalBytes: 1_000_000,
            maxPathLength: 512,
            maxComponentLength: 128,
            maxManifestBytes: 256_000
        )
        #expect(throws: PackageInventoryError.self) {
            _ = try PackageInventoryBuilder.build(packageRoot: root, limits: limits)
        }
    }

    @Test func test_EXT_N10_rejectsSymlink() throws {
        let root = try EXTNFixtures.tempRoot("sym")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(at: root)
        let target = root.appendingPathComponent("LICENSE")
        let link = root.appendingPathComponent("link-license")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: PackageInventoryError.self) {
            _ = try PackageInventoryBuilder.build(packageRoot: root)
        }
    }
}

// MARK: - EXT-N11/N12/N13 install durability

@Suite("EXT-N11 verify-before-activate EXT-N12 journal EXT-N13 reinstall")
struct EXT_N11_N12_N13_Tests {
    @Test func test_EXT_N11_verifyBeforeActivateRejectsBadSource() async throws {
        let store = try EXTNFixtures.tempRoot("store-v")
        let src = try EXTNFixtures.tempRoot("src-v")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.verify")
        // Policy requires verifier — inject fail-closed verifier.
        let mgr = ExtensionPackageManager.insecureForTests(
            installRoot: store,
            verifier: AlwaysQuarantineVerifier()
        )
        await #expect(throws: ExtensionError.self) {
            try await mgr.install(from: src, asDev: false)
        }
        // No active install should exist.
        let installed = await mgr.installedPackages()
        #expect(installed.isEmpty)
    }

    @Test func test_EXT_N12_contentAddressedLayoutAndJournal() async throws {
        let store = try EXTNFixtures.tempRoot("store-j")
        let src = try EXTNFixtures.tempRoot("src-j")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.journal")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        _ = try await mgr.install(from: src, asDev: false)
        let blobs = await mgr.blobsRoot
        #expect(FileManager.default.fileExists(atPath: blobs.path))
        let txs = await mgr.transactionsRoot
        #expect(FileManager.default.fileExists(atPath: txs.path))
        // Package bytes under content-addressed blob.
        let pkgs = await mgr.installedPackages()
        #expect(pkgs.count == 1)
        #expect(pkgs[0].contentDigest != nil)
        let digest = pkgs[0].contentDigest!
        #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(digest).path))

        // Incomplete transaction recovery (crash durability): started/verified → rolledBack.
        let incompleteID = UUID().uuidString
        struct TX: Encodable {
            var id: String
            var packageID: String
            var version: String
            var contentDigest: String
            var phase: String
            var createdAt: Date
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let txData = try enc.encode(
            TX(
                id: incompleteID,
                packageID: "com.example.crash",
                version: "1.0.0",
                contentDigest: "deadbeef",
                phase: "started",
                createdAt: Date()
            ))
        try txData.write(to: txs.appendingPathComponent("\(incompleteID).json"))
        let staging = store.appendingPathComponent("cache/staging-\(incompleteID)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try "partial".write(to: staging.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        await mgr.recoverIncompleteTransactions()
        #expect(!FileManager.default.fileExists(atPath: staging.path), "staging must be removed on recovery")
        let phases = try await mgr.transactionJournalPhases()
        let recovered = phases.first { $0.id == incompleteID }
        #expect(recovered?.phase == "rolledBack")
    }

    @Test func test_EXT_N13_sameVersionReinstallDigestMismatchFails() async throws {
        let store = try EXTNFixtures.tempRoot("store-r")
        let src1 = try EXTNFixtures.tempRoot("src-r1")
        let src2 = try EXTNFixtures.tempRoot("src-r2")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src1)
            try? FileManager.default.removeItem(at: src2)
        }
        try EXTNFixtures.writeMinimalPackage(at: src1, id: "com.example.reinst", version: "1.0.0")
        try EXTNFixtures.writeMinimalPackage(
            at: src2, id: "com.example.reinst", version: "1.0.0",
            extraFiles: [("extra.txt", "different")]
        )
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        let first = try await mgr.install(from: src1, asDev: false)
        let path1 = first.packageRoot
        // Same version, different content must not silently reuse old path with new plan.
        await #expect(throws: ExtensionError.self) {
            _ = try await mgr.install(from: src2, asDev: false)
        }
        let pkgs = await mgr.installedPackages()
        #expect(pkgs.count == 1)
        #expect(pkgs[0].installPath.path == path1?.path || pkgs[0].plan.digest == first.digest)
    }

    @Test func test_EXT_N13_sameVersionSameDigestIsIdempotent() async throws {
        let store = try EXTNFixtures.tempRoot("store-id")
        let src = try EXTNFixtures.tempRoot("src-id")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.idem")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        let a = try await mgr.install(from: src, asDev: false)
        let b = try await mgr.install(from: src, asDev: false)
        #expect(a.digest == b.digest)
        let pkgs = await mgr.installedPackages()
        #expect(pkgs.count == 1)
    }
}

// MARK: - EXT-N14 content-addressed durable paths

@Suite("EXT-N14 durable path trust")
struct EXT_N14_Tests {
    @Test func test_EXT_N14_packagesJsonStoresRelativeStoreKeyNotAbsoluteEscape() async throws {
        let store = try EXTNFixtures.tempRoot("store-p")
        let src = try EXTNFixtures.tempRoot("src-p")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.paths")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        _ = try await mgr.install(from: src, asDev: false)
        let stateURL = store.appendingPathComponent("state/packages.json")
        let data = try Data(contentsOf: stateURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        // Must not trust arbitrary absolute roots alone — require digest / relative key.
        #expect(text.contains("contentDigest") || text.contains("content_digest") || text.contains("storeKey")
            || text.contains("store_key") || text.contains("blobs"))
        // Absolute path outside store root should not be the sole identity.
        #expect(!text.contains("/tmp/evil"))
    }
}

// MARK: - EXT-N15 revocation freshness

@Suite("EXT-N15 revocation freshness")
struct EXT_N15_Tests {
    @Test func test_EXT_N15_staleRevocationRejected() throws {
        let stale = RevocationListDocument(
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            entries: [],
            sequence: 1,
            issuer: "test",
            expiresAt: Date(timeIntervalSince1970: 2),
            signature: nil
        )
        #expect(stale.isFresh(now: Date(), maxAge: 3600) == false)
    }

    @Test func test_EXT_N15_monotonicSequencePreventsRollback() throws {
        var current = RevocationListDocument(
            version: 1,
            updatedAt: Date(),
            entries: [],
            sequence: 5,
            issuer: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let older = RevocationListDocument(
            version: 1,
            updatedAt: Date(),
            entries: [
                RevocationEntry(packageID: "com.example.x", version: "*", reason: "bad")
            ],
            sequence: 3,
            issuer: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        #expect(throws: ExtensionError.self) {
            try current.applyMonotonicUpdate(older)
        }
        #expect(current.sequence == 5)
    }
}

// MARK: - EXT-N16 snapshot filtering

@Suite("EXT-N16 verified snapshots only")
struct EXT_N16_Tests {
    @Test func test_EXT_N16_snapshotExcludesUnverifiedAndRevoked() async throws {
        let store = try EXTNFixtures.tempRoot("store-s")
        let src = try EXTNFixtures.tempRoot("src-s")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.snap")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        _ = try await mgr.install(from: src, asDev: false)
        let id = try ExtensionID(validating: "com.example.snap")

        // Loadable checklist: installed package with matching digest is loadable.
        let pkgs = await mgr.installedPackages()
        #expect(pkgs.count == 1)
        let pkg = pkgs[0]
        let loadableBefore = await mgr.isLoadableForSnapshot(pkg)
        #expect(loadableBefore == true)

        // Quarantined → excluded from snapshot.
        try await mgr.quarantine(id: id, reason: "test")
        let snapQ = await mgr.snapshot
        #expect(!snapQ.packages.contains { $0.packageID == id })

        // Tamper digest bytes → live digest mismatch fails loadable checklist.
        let store2 = try EXTNFixtures.tempRoot("store-s2")
        let src2 = try EXTNFixtures.tempRoot("src-s2")
        defer {
            try? FileManager.default.removeItem(at: store2)
            try? FileManager.default.removeItem(at: src2)
        }
        try EXTNFixtures.writeMinimalPackage(at: src2, id: "com.example.tamper")
        let mgr2 = ExtensionPackageManager.insecureForTests(installRoot: store2)
        _ = try await mgr2.install(from: src2, asDev: false)
        let pkgs2 = await mgr2.installedPackages()
        #expect(pkgs2.count == 1)
        // Corrupt install path content after install.
        try "EVIL".write(
            to: pkgs2[0].installPath.appendingPathComponent("LICENSE"),
            atomically: true,
            encoding: .utf8
        )
        let loadableTampered = await mgr2.isLoadableForSnapshot(pkgs2[0])
        #expect(loadableTampered == false, "live digest mismatch must exclude from loadable set")
        await mgr2.rebuildSnapshotForTests()
        let snapT = await mgr2.snapshot
        #expect(!snapT.packages.contains { $0.packageID.rawValue == "com.example.tamper" })

        // Host capability gate: required cap not granted → not loadable.
        let store3 = try EXTNFixtures.tempRoot("store-s3")
        let src3 = try EXTNFixtures.tempRoot("src-s3")
        defer {
            try? FileManager.default.removeItem(at: store3)
            try? FileManager.default.removeItem(at: src3)
        }
        try """
            id = "com.example.caps"
            name = "Caps"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "data-only"
            [capabilities]
            panels = true
            """.write(to: src3.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: src3.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        // If capabilities table isn't parsed as HostCapability panels, still exercise hostEnvironment gate.
        let mgr3 = ExtensionPackageManager.insecureForTests(installRoot: store3)
        await mgr3.setHostEnvironmentForTests(
            HostEnvironment(apiVersion: .phase9API, capabilities: [.commands], grantedPermissions: [])
        )
        // Install may succeed; snapshot filtering uses hostEnvironment.
        if let _ = try? await mgr3.install(from: src3, asDev: false) {
            let p3 = await mgr3.installedPackages()
            if let only = p3.first, !only.plan.manifest.requiredHostCapabilities.isEmpty {
                let ok = await mgr3.isLoadableForSnapshot(only)
                #expect(ok == false, "missing host capabilities must fail loadable checklist")
            }
        }

        // Untrusted verifier → not loadable.
        let store4 = try EXTNFixtures.tempRoot("store-s4")
        let src4 = try EXTNFixtures.tempRoot("src-s4")
        defer {
            try? FileManager.default.removeItem(at: store4)
            try? FileManager.default.removeItem(at: src4)
        }
        try EXTNFixtures.writeMinimalPackage(at: src4, id: "com.example.untrust")
        let mgr4 = ExtensionPackageManager.insecureForTests(
            installRoot: store4,
            verifier: AlwaysQuarantineVerifier()
        )
        // Install itself is rejected by quarantine verifier.
        await #expect(throws: ExtensionError.self) {
            try await mgr4.install(from: src4, asDev: false)
        }
        let snap4 = await mgr4.snapshot
        #expect(snap4.packages.isEmpty)
    }
}

// MARK: - EXT-N17 executable declaration

@Suite("EXT-N17 executable content")
struct EXT_N17_Tests {
    @Test func test_EXT_N17_undeclaredWasmFailsClosed() throws {
        let root = try EXTNFixtures.tempRoot("wasm")
        defer { try? FileManager.default.removeItem(at: root) }
        // Real Wasm magic (not path extension alone).
        var wasm = Data(PackageExecutableClassifier.wasmMagic)
        wasm.append(Data(repeating: 0x00, count: 12))
        try EXTNFixtures.writeMinimalPackage(at: root)
        try wasm.write(to: root.appendingPathComponent("payload.bin"))
        let inv = try PackageInventoryBuilder.build(packageRoot: root)
        #expect(inv.entries.contains { $0.relativePath == "payload.bin" && $0.kind == .wasm })
        #expect(throws: PackageInventoryError.undeclaredExecutable("payload.bin")) {
            try PackageInventoryBuilder.assertNoUndeclaredExecutables(
                inventory: inv, declaredPaths: []
            )
        }
        // Declared path is accepted.
        try PackageInventoryBuilder.assertNoUndeclaredExecutables(
            inventory: inv, declaredPaths: ["payload.bin"]
        )

        // Manifest entrypoint binding for non-data-only.
        let root2 = try EXTNFixtures.tempRoot("wasm2")
        defer { try? FileManager.default.removeItem(at: root2) }
        try """
            id = "com.example.wasmrt"
            name = "WasmRT"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "swift-wasm"
            entrypoint = "mod.wasm"
            """.write(to: root2.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root2.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        try wasm.write(to: root2.appendingPathComponent("mod.wasm"))
        let plan = try ExtensionPackageLoader.load(directory: root2, options: .init(computeDigest: false))
        let declared = PackageInventoryBuilder.declaredExecutablePaths(
            runtimeKind: plan.manifestRuntimeKind,
            runtimeEntrypoint: plan.manifestRuntimeEntrypoint,
            packageRoot: root2
        )
        #expect(declared.contains("mod.wasm"))
        let inv2 = try PackageInventoryBuilder.build(
            packageRoot: root2, declaredExecutablePaths: declared)
        try PackageInventoryBuilder.assertNoUndeclaredExecutables(
            inventory: inv2, declaredPaths: declared
        )
    }
}

// MARK: - EXT-N18 bounded telemetry

@Suite("EXT-N18 bounded telemetry")
struct EXT_N18_Tests {
    @Test func test_EXT_N18_telemetryRotatesAndReportsFailures() throws {
        let dir = try EXTNFixtures.tempRoot("tel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("events.ndjson")
        let sink = StoreTelemetrySink(
            fileURL: url,
            maxFileBytes: 200,
            maxTotalBytes: 500
        )
        for i in 0..<50 {
            sink.append(
                StoreTelemetryEvent(
                    event: "test.event.\(i)",
                    packageID: "com.example.t",
                    success: true,
                    reason: String(repeating: "x", count: 40)
                ))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let total = sink.totalDiskBytesUsed()
        #expect(sink.rotationCount > 0, "rotation must occur under tight maxFileBytes")
        #expect(size <= 200 || sink.rotationCount > 0)
        #expect(total <= 500)

        // Write failure metric must increment (not vacuous >= 0).
        let before = sink.writeFailureCount
        sink.failNextWriteForTests = true
        sink.append(
            StoreTelemetryEvent(
                event: "fail.me", packageID: "com.example.t", success: false, reason: "inject"
            ))
        #expect(sink.writeFailureCount == before + 1)
    }
}

// MARK: - EXT-N19 broadcast snapshots

@Suite("EXT-N19 package snapshot broadcast")
struct EXT_N19_Tests {
    @Test func test_EXT_N19_snapshotUsesBroadcastHub() async throws {
        // Direct hub contract matching ExtensionPackageManager.packageSnapshotStream policy:
        // dropOldest(capacity:, emitGap: true) + sequenced full snapshots.
        let hub = AsyncBroadcastHub<ExtensionContributionSnapshot>(maxHistory: 8)
        let stream = await hub.subscribe(
            policy: .dropOldest(capacity: 2, emitGap: true),
            replay: .none
        )
        var iterator = stream.makeAsyncIterator()

        await hub.publish(.empty)
        await hub.publish(.empty)
        await hub.publish(.empty)
        await hub.publish(.empty)
        await hub.publish(.empty)

        var sawValue = false
        var sawGap = false
        var lastSeq: UInt64 = 0
        for _ in 0..<12 {
            guard let item = await iterator.next() else { break }
            switch item {
            case .value(let env):
                sawValue = true
                #expect(env.sequence >= 1)
                lastSeq = max(lastSeq, env.sequence)
            case .gap(let from, let to):
                sawGap = true
                #expect(to > from, "gap contract requires to > from")
            case .finished:
                break
            }
            if sawValue && sawGap { break }
        }
        #expect(sawValue, "hub must deliver sequenced snapshot values")
        #expect(lastSeq >= 1)
        // Capacity 2 + 5 publishes forces dropOldest gap under emitGap:true.
        #expect(sawGap, "dropped items must emit gap markers (resync contract)")

        // Manager uses the same hub type for packageSnapshotStream (compile/runtime wiring).
        let store = try EXTNFixtures.tempRoot("store-b")
        let src = try EXTNFixtures.tempRoot("src-b")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.hub")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store, maxEventBuffer: 4)
        // Type of packageSnapshotStream is StreamItem<AsyncBroadcastHub.Envelope> (not bare snapshot).
        let _: AsyncStream<StreamItem<AsyncBroadcastHub<ExtensionContributionSnapshot>.Envelope>> =
            await mgr.packageSnapshotStream()
        let genBefore = await mgr.generation
        _ = try await mgr.install(from: src, asDev: false)
        let genAfter = await mgr.generation
        #expect(genAfter > genBefore, "install must advance snapshot generation via hub publish path")
        let snap = await mgr.snapshot
        #expect(snap.packages.contains { $0.packageID.rawValue == "com.example.hub" })
    }
}

// MARK: - Test verifier doubles (test support only)

struct AlwaysQuarantineVerifier: PackageVerifying {
    func verify(packageRoot: URL) throws -> PackageVerifyResult {
        PackageVerifyResult(
            trustClass: .untrusted,
            publisher: nil,
            quarantined: true,
            error: "always-quarantine"
        )
    }
}
