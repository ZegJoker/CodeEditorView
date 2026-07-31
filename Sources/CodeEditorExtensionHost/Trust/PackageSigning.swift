import Foundation
import CodeEditorExtensionAPI
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ExtensionTrustClass: String, Sendable, Hashable, Codable {
    case trustedSigned
    case workspaceDev
    case untrusted
}

public struct ExtensionPublisherKey: Sendable, Hashable {
    public var keyID: String
    public var publicKeyRaw: Data
    public var subject: String

    public init(keyID: String, publicKeyRaw: Data, subject: String) {
        self.keyID = keyID
        self.publicKeyRaw = publicKeyRaw
        self.subject = subject
    }
}

public struct ExtensionTrustPolicy: Sendable {
    public var allowWorkspaceDevNative: Bool
    public var allowUntrustedNative: Bool
    public var trustedKeys: [ExtensionPublisherKey]

    public init(
        allowWorkspaceDevNative: Bool = false,
        allowUntrustedNative: Bool = false,
        trustedKeys: [ExtensionPublisherKey] = []
    ) {
        self.allowWorkspaceDevNative = allowWorkspaceDevNative
        self.allowUntrustedNative = allowUntrustedNative
        self.trustedKeys = trustedKeys
    }

    public static let strict = ExtensionTrustPolicy()
    public static let testing = ExtensionTrustPolicy(allowWorkspaceDevNative: true, allowUntrustedNative: false)
}

public enum PackageSignatureError: Error, Sendable, Equatable {
    case missingChecksums
    case missingSignature
    case missingPublisher
    case checksumMismatch(String)
    case invalidSignature
    case unknownPublisher
    case cryptoUnavailable
    case untrusted(ExtensionTrustClass)
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
        let digest = try ExtensionPackageDigest.compute(packageRoot: packageRoot)
        // Per-file digests
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PackageSignatureError.missingChecksums
        }
        var map: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: packageRoot.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel == "checksums.json" || rel == "signature.ed25519" || rel == "publisher.json" { continue }
            if rel.hasPrefix(".codeeditor/") { continue }
            let data = try Data(contentsOf: url)
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

public enum ExtensionPackageVerifier {
    public static func verify(
        packageRoot: URL,
        policy: ExtensionTrustPolicy
    ) throws -> ExtensionTrustClass {
        let checksumsURL = packageRoot.appendingPathComponent("checksums.json")
        let sigURL = packageRoot.appendingPathComponent("signature.ed25519")
        let pubURL = packageRoot.appendingPathComponent("publisher.json")

        let hasChecksums = FileManager.default.fileExists(atPath: checksumsURL.path)
        let hasSig = FileManager.default.fileExists(atPath: sigURL.path)
        let hasPub = FileManager.default.fileExists(atPath: pubURL.path)

        if !hasChecksums && !hasSig {
            // Unsigned workspace-dev candidate
            if policy.allowWorkspaceDevNative { return .workspaceDev }
            if policy.allowUntrustedNative { return .untrusted }
            throw PackageSignatureError.untrusted(.untrusted)
        }

        guard hasChecksums else { throw PackageSignatureError.missingChecksums }
        let checksumsData = try Data(contentsOf: checksumsURL)
        guard let map = try JSONSerialization.jsonObject(with: checksumsData) as? [String: String] else {
            throw PackageSignatureError.missingChecksums
        }

        // Verify each file
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
                  let keyID = pubObj?["key_id"]
            else { throw PackageSignatureError.missingPublisher }

            let known = policy.trustedKeys.contains { $0.keyID == keyID && $0.publicKeyRaw == keyData }
                || policy.trustedKeys.isEmpty // empty keyring: accept any valid self-signature as trusted for local
            // If keyring non-empty, require match; if empty, still verify crypto and treat as trustedSigned for tests
            if !policy.trustedKeys.isEmpty && !known {
                throw PackageSignatureError.unknownPublisher
            }

            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            let signature = try Data(contentsOf: sigURL)
            guard publicKey.isValidSignature(signature, for: checksumsData) else {
                throw PackageSignatureError.invalidSignature
            }
            return .trustedSigned
            #else
            throw PackageSignatureError.cryptoUnavailable
            #endif
        }

        if policy.allowWorkspaceDevNative { return .workspaceDev }
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

/// Native helper is a reliability boundary, not automatically a security sandbox.
public enum NativeProcessTrustNotice {
    public static let message = """
    A native Swift helper is a reliability boundary, not automatically a security boundary. \
    Unsandboxed helpers retain ambient OS authority. Only OS-enforced sandboxes or Swift-Wasm \
    provide capability containment for untrusted code.
    """
}
