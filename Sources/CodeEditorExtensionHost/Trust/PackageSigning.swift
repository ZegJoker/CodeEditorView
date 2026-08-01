import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensions
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ExtensionTrustClass: String, Sendable, Hashable, Codable {
    case trustedSigned
    case workspaceDev
    case untrusted

    public var dto: ExtensionTrustClassDTO {
        switch self {
        case .trustedSigned: return .trustedSigned
        case .workspaceDev: return .workspaceDev
        case .untrusted: return .untrusted
        }
    }
}

public struct ExtensionPublisherKey: Sendable, Hashable, Codable {
    public var keyID: String
    public var publicKeyRaw: Data
    public var subject: String

    public init(keyID: String, publicKeyRaw: Data, subject: String) {
        self.keyID = keyID
        self.publicKeyRaw = publicKeyRaw
        self.subject = subject
    }
}

public struct PublisherKeyring: Sendable, Hashable, Codable {
    public var keys: [ExtensionPublisherKey]
    public var revokedKeyIDs: Set<String>

    public init(keys: [ExtensionPublisherKey] = [], revokedKeyIDs: Set<String> = []) {
        self.keys = keys
        self.revokedKeyIDs = revokedKeyIDs
    }

    public static func load(from url: URL) throws -> PublisherKeyring {
        let data = try Data(contentsOf: url)
        // Support simplified JSON: { "keys": [ {key_id, public_key_b64, subject} ], "revoked_key_ids": [] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageSignatureError.missingPublisher
        }
        var keys: [ExtensionPublisherKey] = []
        if let arr = obj["keys"] as? [[String: String]] {
            for item in arr {
                guard let id = item["key_id"] ?? item["keyID"],
                      let b64 = item["public_key_b64"] ?? item["publicKeyB64"],
                      let raw = Data(base64Encoded: b64),
                      let subject = item["subject"]
                else { continue }
                keys.append(ExtensionPublisherKey(keyID: id, publicKeyRaw: raw, subject: subject))
            }
        }
        let revoked = Set((obj["revoked_key_ids"] as? [String]) ?? (obj["revokedKeyIDs"] as? [String]) ?? [])
        return PublisherKeyring(keys: keys, revokedKeyIDs: revoked)
    }

    public func save(to url: URL) throws {
        let keysJSON: [[String: String]] = keys.map {
            [
                "key_id": $0.keyID,
                "public_key_b64": $0.publicKeyRaw.base64EncodedString(),
                "subject": $0.subject,
            ]
        }
        let obj: [String: Any] = [
            "keys": keysJSON,
            "revoked_key_ids": Array(revokedKeyIDs).sorted(),
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

public struct ExtensionTrustPolicy: Sendable {
    public var allowWorkspaceDevNative: Bool
    public var allowUntrustedNative: Bool
    /// When false (default), empty keyring rejects signed packages as unknownPublisher.
    public var allowUnknownSelfSigned: Bool
    public var trustedKeys: [ExtensionPublisherKey]
    public var revokedKeyIDs: Set<String>
    public var licensePolicy: PackageSBOM.LicensePolicy

    public init(
        allowWorkspaceDevNative: Bool = false,
        allowUntrustedNative: Bool = false,
        allowUnknownSelfSigned: Bool = false,
        trustedKeys: [ExtensionPublisherKey] = [],
        revokedKeyIDs: Set<String> = [],
        licensePolicy: PackageSBOM.LicensePolicy = .permissive
    ) {
        self.allowWorkspaceDevNative = allowWorkspaceDevNative
        self.allowUntrustedNative = allowUntrustedNative
        self.allowUnknownSelfSigned = allowUnknownSelfSigned
        self.trustedKeys = trustedKeys
        self.revokedKeyIDs = revokedKeyIDs
        self.licensePolicy = licensePolicy
    }

    public static let strict = ExtensionTrustPolicy()
    public static let testing = ExtensionTrustPolicy(
        allowWorkspaceDevNative: true,
        allowUntrustedNative: false,
        allowUnknownSelfSigned: true
    )

    public mutating func apply(keyring: PublisherKeyring) {
        trustedKeys = keyring.keys
        revokedKeyIDs.formUnion(keyring.revokedKeyIDs)
    }
}

public enum PackageSignatureError: Error, Sendable, Equatable {
    case missingChecksums
    case missingSignature
    case missingPublisher
    case checksumMismatch(String)
    case invalidSignature
    case unknownPublisher
    case revokedKey(String)
    case cryptoUnavailable
    case untrusted(ExtensionTrustClass)
    case license(String)
    case sbom(String)
}

/// Ed25519 package signing over canonical checksums.json.
public enum ExtensionPackageSigner {
    public struct KeyPair: Sendable {
        public var publicKeyRaw: Data
        public var privateKeyRaw: Data
        public var keyID: String
    }

    public static func generateKeyPair(keyID: String = UUID().uuidString) throws -> KeyPair {
        #if canImport(CryptoKit)
        let privateKey = Curve25519.Signing.PrivateKey()
        return KeyPair(
            publicKeyRaw: privateKey.publicKey.rawRepresentation,
            privateKeyRaw: privateKey.rawRepresentation,
            keyID: keyID
        )
        #else
        throw PackageSignatureError.cryptoUnavailable
        #endif
    }

    public static func writeKeyPair(_ pair: KeyPair, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pair.privateKeyRaw.write(to: directory.appendingPathComponent("ed25519.private"), options: .atomic)
        try pair.publicKeyRaw.write(to: directory.appendingPathComponent("ed25519.public"), options: .atomic)
        let meta = """
        {"key_id":"\(pair.keyID)","public_key_b64":"\(pair.publicKeyRaw.base64EncodedString())"}
        """
        try meta.write(to: directory.appendingPathComponent("key.json"), atomically: true, encoding: .utf8)
    }

    public static func writeChecksums(packageRoot: URL) throws -> Data {
        let digestMap = try fileDigests(packageRoot: packageRoot)
        let data = try JSONSerialization.data(withJSONObject: digestMap, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: packageRoot.appendingPathComponent("checksums.json"), options: .atomic)
        return data
    }

    public static func sign(packageRoot: URL, privateKeyRaw: Data, keyID: String, subject: String) throws {
        #if canImport(CryptoKit)
        let checksums = try writeChecksums(packageRoot: packageRoot)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        let signature = try privateKey.signature(for: checksums)
        try signature.write(to: packageRoot.appendingPathComponent("signature.ed25519"), options: .atomic)
        let publisher: [String: String] = [
            "key_id": keyID,
            "subject": subject,
            "public_key_b64": privateKey.publicKey.rawRepresentation.base64EncodedString(),
        ]
        let pubData = try JSONSerialization.data(withJSONObject: publisher, options: [.sortedKeys, .prettyPrinted])
        try pubData.write(to: packageRoot.appendingPathComponent("publisher.json"), options: .atomic)
        #else
        throw PackageSignatureError.cryptoUnavailable
        #endif
    }

    public static func fileDigests(packageRoot: URL) throws -> [String: String] {
        let root = packageRoot.resolvingSymlinksInPath()
        let digest = try ExtensionPackageDigest.compute(packageRoot: root)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PackageSignatureError.missingChecksums
        }
        var map: [String: String] = [:]
        let rootPath = root.path
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let file = url.resolvingSymlinksInPath()
            var rel = file.path
            if rel.hasPrefix(rootPath) {
                rel = String(rel.dropFirst(rootPath.count))
            }
            rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel == "checksums.json" || rel == "signature.ed25519" || rel == "publisher.json" { continue }
            if rel.hasPrefix(".codeeditor/") { continue }
            // Ignore authoring key material accidentally left under the package tree.
            if rel.hasPrefix("keys/") || rel == "ed25519.private" || rel == "ed25519.public" { continue }
            let data = try Data(contentsOf: file)
            map[rel] = sha256Hex(data)
        }
        map["__package__"] = digest
        return map
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        String(data.count)
        #endif
    }
}

public struct PackageVerifyReport: Sendable {
    public var trustClass: ExtensionTrustClass
    public var publisher: String?
    public var keyID: String?
    public var errors: [String]
}

public enum ExtensionPackageVerifier {
    public static func verify(
        packageRoot: URL,
        policy: ExtensionTrustPolicy
    ) throws -> ExtensionTrustClass {
        try verifyDetailed(packageRoot: packageRoot, policy: policy).trustClass
    }

    public static func verifyDetailed(
        packageRoot: URL,
        policy: ExtensionTrustPolicy
    ) throws -> PackageVerifyReport {
        let checksumsURL = packageRoot.appendingPathComponent("checksums.json")
        let sigURL = packageRoot.appendingPathComponent("signature.ed25519")
        let pubURL = packageRoot.appendingPathComponent("publisher.json")

        let hasChecksums = FileManager.default.fileExists(atPath: checksumsURL.path)
        let hasSig = FileManager.default.fileExists(atPath: sigURL.path)
        let hasPub = FileManager.default.fileExists(atPath: pubURL.path)

        // License / SBOM policy (when plan can load)
        if let plan = try? ExtensionPackageLoader.load(directory: packageRoot, options: .init(computeDigest: false)) {
            do {
                try PackageSBOM.enforce(packageRoot: packageRoot, plan: plan, policy: policy.licensePolicy)
            } catch let e as PackageSBOM.SBOMError {
                throw PackageSignatureError.license(String(describing: e))
            }
        }

        if !hasChecksums && !hasSig {
            if policy.allowWorkspaceDevNative {
                return PackageVerifyReport(trustClass: .workspaceDev, publisher: nil, keyID: nil, errors: [])
            }
            if policy.allowUntrustedNative {
                return PackageVerifyReport(trustClass: .untrusted, publisher: nil, keyID: nil, errors: [])
            }
            throw PackageSignatureError.untrusted(.untrusted)
        }

        guard hasChecksums else { throw PackageSignatureError.missingChecksums }
        let checksumsData = try Data(contentsOf: checksumsURL)
        guard let map = try JSONSerialization.jsonObject(with: checksumsData) as? [String: String] else {
            throw PackageSignatureError.missingChecksums
        }

        let current = try ExtensionPackageSigner.fileDigests(packageRoot: packageRoot)
        for (path, expected) in map where path != "__package__" {
            guard let actual = current[path], actual == expected else {
                throw PackageSignatureError.checksumMismatch(path)
            }
        }

        if hasSig && hasPub {
            #if canImport(CryptoKit)
            let pubObj = try JSONSerialization.jsonObject(with: Data(contentsOf: pubURL)) as? [String: String]
            guard let b64 = pubObj?["public_key_b64"],
                  let keyData = Data(base64Encoded: b64),
                  let keyID = pubObj?["key_id"],
                  let subject = pubObj?["subject"]
            else { throw PackageSignatureError.missingPublisher }

            if policy.revokedKeyIDs.contains(keyID) {
                throw PackageSignatureError.revokedKey(keyID)
            }

            let known = policy.trustedKeys.contains { $0.keyID == keyID && $0.publicKeyRaw == keyData }
            if policy.trustedKeys.isEmpty {
                // Fail closed unless explicit test escape hatch
                if !policy.allowUnknownSelfSigned {
                    throw PackageSignatureError.unknownPublisher
                }
            } else if !known {
                throw PackageSignatureError.unknownPublisher
            }

            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            let signature = try Data(contentsOf: sigURL)
            guard publicKey.isValidSignature(signature, for: checksumsData) else {
                throw PackageSignatureError.invalidSignature
            }
            return PackageVerifyReport(
                trustClass: .trustedSigned,
                publisher: subject,
                keyID: keyID,
                errors: []
            )
            #else
            throw PackageSignatureError.cryptoUnavailable
            #endif
        }

        if policy.allowWorkspaceDevNative {
            return PackageVerifyReport(trustClass: .workspaceDev, publisher: nil, keyID: nil, errors: [])
        }
        throw PackageSignatureError.untrusted(.untrusted)
    }

    public static func assertNativeLaunchAllowed(
        trust: ExtensionTrustClass,
        policy: ExtensionTrustPolicy
    ) throws {
        switch trust {
        case .trustedSigned:
            return
        case .workspaceDev:
            guard policy.allowWorkspaceDevNative else { throw PackageSignatureError.untrusted(trust) }
        case .untrusted:
            guard policy.allowUntrustedNative else { throw PackageSignatureError.untrusted(trust) }
        }
    }
}

/// Adapter for `ExtensionPackageManager` injection.
public struct HostPackageVerifier: PackageVerifying {
    public var policy: ExtensionTrustPolicy

    public init(policy: ExtensionTrustPolicy = .strict) {
        self.policy = policy
    }

    public func verify(packageRoot: URL) throws -> PackageVerifyResult {
        do {
            let report = try ExtensionPackageVerifier.verifyDetailed(packageRoot: packageRoot, policy: policy)
            return PackageVerifyResult(
                trustClass: report.trustClass.dto,
                publisher: report.publisher,
                quarantined: false,
                error: nil
            )
        } catch {
            return PackageVerifyResult(
                trustClass: .untrusted,
                publisher: nil,
                quarantined: true,
                error: String(describing: error)
            )
        }
    }
}

/// Native helper is a reliability boundary, not automatically a security sandbox.
public enum NativeProcessTrustNotice {
    public static let message = """
    A native Swift helper is a reliability boundary, not automatically a security boundary. \
    Unsandboxed helpers retain ambient OS authority. Only OS-enforced sandboxes or Swift-Wasm \
    provide capability containment for untrusted code.
    """
}
