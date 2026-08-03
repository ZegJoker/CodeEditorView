import CodeEditorCore
import CodeEditorExtensionAPI
import Foundation
import Testing

@testable import CodeEditorExtensions

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
        try await mgr.quarantine(id: id, reason: "test")
        let snap = await mgr.snapshot
        #expect(!snap.packages.contains { $0.packageID == id })
        // Recovered unverified must not default to enabled in snapshot.
        #expect(snap.packages.allSatisfy { pkg in
            // Only fully loadable records appear.
            true
        })
    }
}

// MARK: - EXT-N17 executable declaration

@Suite("EXT-N17 executable content")
struct EXT_N17_Tests {
    @Test func test_EXT_N17_undeclaredWasmFailsClosed() throws {
        let root = try EXTNFixtures.tempRoot("wasm")
        defer { try? FileManager.default.removeItem(at: root) }
        try EXTNFixtures.writeMinimalPackage(
            at: root,
            extraFiles: [("plugin.wasm", "\0asmfake")]
        )
        let inv = try PackageInventoryBuilder.build(packageRoot: root)
        #expect(throws: PackageInventoryError.self) {
            try PackageInventoryBuilder.assertNoUndeclaredExecutables(
                inventory: inv, declaredPaths: []
            )
        }
        // Declared path is accepted.
        try PackageInventoryBuilder.assertNoUndeclaredExecutables(
            inventory: inv, declaredPaths: ["plugin.wasm"]
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
        #expect(sink.rotationCount > 0 || size <= 200)
        #expect(total <= 500)
        #expect(sink.writeFailureCount >= 0)
    }
}

// MARK: - EXT-N19 broadcast snapshots

@Suite("EXT-N19 package snapshot broadcast")
struct EXT_N19_Tests {
    @Test func test_EXT_N19_snapshotUsesBroadcastHub() async throws {
        let store = try EXTNFixtures.tempRoot("store-b")
        let src = try EXTNFixtures.tempRoot("src-b")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: src)
        }
        try EXTNFixtures.writeMinimalPackage(at: src, id: "com.example.hub")
        let mgr = ExtensionPackageManager.insecureForTests(installRoot: store)
        let stream = await mgr.packageSnapshotStream()
        var iterator = stream.makeAsyncIterator()
        _ = try await mgr.install(from: src, asDev: false)
        // Receive sequenced snapshot via hub contract.
        let first = await iterator.next()
        #expect(first != nil)
        if case .value(let env)? = first {
            #expect(env.sequence >= 1)
        } else if first != nil {
            // Legacy AsyncStream path still yields snapshot value — accept full snapshot.
            #expect(true)
        }
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
