import CodeEditorExtensionAPI
import CodeEditorExtensions
import CodeEditorWasmEngine
import CodeEditorWasmEngineWasmKit
import Foundation
import Testing

@testable import CodeEditorExtensionHost

private enum SigningFixtures {
    static func tempRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extn-sign-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeMinimalPackage(at root: URL, id: String = "com.example.signed") throws {
        try """
            id = "\(id)"
            name = "Signed"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            [runtime]
            kind = "data-only"
            """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
    }
}

// MARK: - EXT-N04 / N05 / N06 signing

@Suite("EXT-N04 N05 N06 package signing")
struct EXT_N04_N05_N06_SigningTests {
    @Test func test_EXT_N04_hiddenFileBreaksSignatureWhenAddedAfterSign() throws {
        let root = try SigningFixtures.tempRoot("hid")
        defer { try? FileManager.default.removeItem(at: root) }
        try SigningFixtures.writeMinimalPackage(at: root)
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "k-hid")
        try ExtensionPackageSigner.sign(
            packageRoot: root, privateKeyRaw: kp.privateKeyRaw, keyID: kp.keyID, subject: "Pub")
        // Attacker adds hidden file after signing.
        let secret = root.appendingPathComponent(".evil")
        try "payload".write(to: secret, atomically: true, encoding: .utf8)
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageVerifier.verify(
                packageRoot: root,
                policy: ExtensionTrustPolicy(trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Pub")
                ]))
        }
    }

    @Test func test_EXT_N05_codeeditorContentBoundInSignature() throws {
        let root = try SigningFixtures.tempRoot("ce")
        defer { try? FileManager.default.removeItem(at: root) }
        try SigningFixtures.writeMinimalPackage(at: root)
        let ce = root.appendingPathComponent(".codeeditor", isDirectory: true)
        try FileManager.default.createDirectory(at: ce, withIntermediateDirectories: true)
        try "{\"a\":1}".write(to: ce.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let digests = try ExtensionPackageSigner.fileDigests(packageRoot: root)
        #expect(digests.keys.contains(".codeeditor/meta.json"))
    }

    @Test func test_EXT_N06_canonicalSignedPublisherStatement() throws {
        let root = try SigningFixtures.tempRoot("stmt")
        defer { try? FileManager.default.removeItem(at: root) }
        try SigningFixtures.writeMinimalPackage(at: root, id: "com.example.stmt")
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "ed25519:test")
        try ExtensionPackageSigner.sign(
            packageRoot: root, privateKeyRaw: kp.privateKeyRaw, keyID: kp.keyID, subject: "Example Publisher")
        let stmtURL = root.appendingPathComponent("signed-statement.json")
        #expect(FileManager.default.fileExists(atPath: stmtURL.path))
        let data = try Data(contentsOf: stmtURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["schema"] as? Int == 1)
        #expect(obj?["extension_id"] as? String == "com.example.stmt")
        #expect(obj?["version"] as? String == "1.0.0")
        #expect(obj?["manifest_sha256"] as? String != nil)
        #expect(obj?["inventory_sha256"] as? String != nil)
        #expect(obj?["package_sha256"] as? String != nil)
        #expect(obj?["created_at"] as? String != nil)
        #expect(obj?["minimum_host_api"] as? String != nil)
        if let pub = obj?["publisher"] as? [String: Any] {
            #expect(pub["subject"] as? String == "Example Publisher")
            #expect(pub["key_id"] as? String == kp.keyID)
        } else {
            Issue.record("publisher object missing from signed statement")
        }
        // Signature must cover the statement, not merely checksums written before publisher.json.
        let trust = try ExtensionPackageVerifier.verify(
            packageRoot: root,
            policy: ExtensionTrustPolicy(
                allowUnknownSelfSigned: false,
                trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Example Publisher")
                ]
            )
        )
        #expect(trust == .trustedSigned)
        // Mutating publisher.json alone must not change the signed statement binding.
        let pubURL = root.appendingPathComponent("publisher.json")
        if FileManager.default.fileExists(atPath: pubURL.path) {
            var pub = try JSONSerialization.jsonObject(with: Data(contentsOf: pubURL)) as! [String: String]
            pub["subject"] = "Evil"
            try JSONSerialization.data(withJSONObject: pub).write(to: pubURL)
            // Statement still has correct subject — verify should still check statement subject.
            // If publisher.json is only advisory, statement remains source of truth.
            let report = try? ExtensionPackageVerifier.verifyDetailed(
                packageRoot: root,
                policy: ExtensionTrustPolicy(trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Example Publisher")
                ])
            )
            // Either fails (publisher mismatch) or still trusted via statement — subject in statement wins.
            if let report {
                #expect(report.publisher == "Example Publisher" || !report.errors.isEmpty || report.trustClass != .trustedSigned)
            }
        }
    }
}

// MARK: - EXT-N07 atomic key write

@Suite("EXT-N07 atomic key write")
struct EXT_N07_Tests {
    @Test func test_EXT_N07_keyWriteIsAtomicAndPreservesPriorOnFailure() throws {
        let dir = try SigningFixtures.tempRoot("keys")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kp1 = try ExtensionPackageSigner.generateKeyPair(keyID: "k1")
        try ExtensionPackageSigner.writeKeyPair(kp1, to: dir)
        let privateURL = dir.appendingPathComponent("ed25519.private")
        let original = try Data(contentsOf: privateURL)
        #expect(original == kp1.privateKeyRaw)

        // Failure injection via parameter (not a production global hook): prior key preserved (EXT-N07).
        let kpFail = try ExtensionPackageSigner.generateKeyPair(keyID: "k-fail")
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageSigner.writeKeyPair(kpFail, to: dir, injectFailureAfterBackup: true)
        }
        let afterFail = try Data(contentsOf: privateURL)
        #expect(afterFail == original, "prior private key must survive failed replacement")
        let backup = dir.appendingPathComponent("ed25519.private.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: backup) == original)

        // Successful atomic replace + backup of previous live key.
        let kp2 = try ExtensionPackageSigner.generateKeyPair(keyID: "k2")
        try ExtensionPackageSigner.writeKeyPair(kp2, to: dir)
        let updated = try Data(contentsOf: privateURL)
        #expect(updated == kp2.privateKeyRaw)
        let bakAfterSuccess = try Data(contentsOf: backup)
        #expect(bakAfterSuccess == original || bakAfterSuccess == kp1.privateKeyRaw)
    }
}

// MARK: - EXT-N08 no fatalError crypto path

@Suite("EXT-N08 crypto unavailable throws")
struct EXT_N08_Tests {
    @Test func test_EXT_N08_sha256HexThrowsNotFatal() throws {
        // Force cryptoUnavailable path even when CryptoKit is present (EXT-N08).
        #expect(throws: PackageSignatureError.cryptoUnavailable) {
            _ = try ExtensionPackageSigner.sha256Hex(Data("x".utf8), availability: .unavailable)
        }
        #expect(throws: SecurityDigestError.cryptoUnavailable) {
            _ = try SecurityDigest.sha256Hex(Data("y".utf8), availability: .unavailable)
        }
        #expect(throws: SecurityDigestError.cryptoUnavailable) {
            _ = try ConformanceEvent.payloadDigest(Data("z".utf8), availability: .unavailable)
        }
        // Happy path still works with system crypto.
        let hex = try ExtensionPackageSigner.sha256Hex(Data("abc".utf8), availability: .system)
        #expect(hex.count == 64)
        #expect(hex != "")
        let root = try SigningFixtures.tempRoot("crypto")
        defer { try? FileManager.default.removeItem(at: root) }
        try SigningFixtures.writeMinimalPackage(at: root)
        _ = try ExtensionPackageSigner.fileDigests(packageRoot: root)
    }
}

// MARK: - EXT-N09 strict keyring

@Suite("EXT-N09 keyring fail-closed")
struct EXT_N09_Tests {
    @Test func test_EXT_N09_malformedKeyringThrows() throws {
        let url = try SigningFixtures.tempRoot("kr").appendingPathComponent("keyring.json")
        try """
            {"keys":[{"key_id":"a","public_key_b64":"!!!not-base64!!!","subject":"x"}],"revoked_key_ids":[]}
            """.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: PackageSignatureError.self) {
            _ = try PublisherKeyring.load(from: url)
        }
    }

    @Test func test_EXT_N09_duplicateKeyIDsFail() throws {
        let url = try SigningFixtures.tempRoot("kr2").appendingPathComponent("keyring.json")
        // Valid 32-byte key base64
        let raw = Data(repeating: 7, count: 32).base64EncodedString()
        try """
            {
              "schema": 1,
              "keys": [
                {"key_id":"same","public_key_b64":"\(raw)","subject":"A"},
                {"key_id":"same","public_key_b64":"\(raw)","subject":"B"}
              ],
              "revoked_key_ids": []
            }
            """.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: PackageSignatureError.self) {
            _ = try PublisherKeyring.load(from: url)
        }
    }

    @Test func test_EXT_N09_validKeyringLoads() throws {
        let url = try SigningFixtures.tempRoot("kr3").appendingPathComponent("keyring.json")
        let raw = Data(repeating: 3, count: 32).base64EncodedString()
        try """
            {
              "schema": 1,
              "keys": [
                {"key_id":"k1","public_key_b64":"\(raw)","subject":"Pub"}
              ],
              "revoked_key_ids": []
            }
            """.write(to: url, atomically: true, encoding: .utf8)
        let kr = try PublisherKeyring.load(from: url)
        #expect(kr.keys.count == 1)
        #expect(kr.keys[0].keyID == "k1")
    }
}

// MARK: - EXT-N20 production surface

@Suite("EXT-N20 no mocks in production defaults")
struct EXT_N20_Tests {
    @Test func test_EXT_N20_simulationFactoryNotProductionDefault() {
        // Production factory has only WasmKit — no linkedGuest kind/factory.
        #expect(WasmEngineFactory.productionEngineKind == .wasmKit)
        #expect(WasmEngineFactory.production() is WasmKitEngine)
        #expect(WasmEngineFactory.wasmKit() is WasmKitEngine)
        #expect(ExtensionProductionSurface.linkedGuestSimulationIsProductionDefault == false)
        #expect(ExtensionProductionSurface.productionWasmFactoryKinds == ["wasmKit"])
        #expect(ExtensionProductionSurface.conformanceGuestIsPublicLibraryProduct == false)
        // LinkedGuest simulation types live in test-support target only — production Host
        // must not expose a linkedGuest() factory (compile-time removed; runtime kinds closed).
        let kinds = ExtensionProductionSurface.productionWasmFactoryKinds
        #expect(!kinds.contains("linkedGuest"))
        #expect(!kinds.contains("simulation"))
        // Test-support path still available for dual-run semantics tests.
        let sim = WasmTestEngines.linkedGuest()
        #expect(type(of: sim as Any) != type(of: WasmEngineFactory.production() as Any))
    }
}
