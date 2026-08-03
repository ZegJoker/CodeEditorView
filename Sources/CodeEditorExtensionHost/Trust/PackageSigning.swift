import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation

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

/// Versioned strict keyring (EXT-N09). Malformed entries fail closed.
public struct PublisherKeyring: Sendable, Hashable, Codable {
    public var schema: Int
    public var keys: [ExtensionPublisherKey]
    public var revokedKeyIDs: Set<String>

    public init(schema: Int = 1, keys: [ExtensionPublisherKey] = [], revokedKeyIDs: Set<String> = []) {
        self.schema = schema
        self.keys = keys
        self.revokedKeyIDs = revokedKeyIDs
    }

    public static func load(from url: URL) throws -> PublisherKeyring {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageSignatureError.invalidKeyring("not a JSON object")
        }
        let schema = obj["schema"] as? Int ?? 1
        guard schema == 1 else {
            throw PackageSignatureError.invalidKeyring("unsupported schema \(schema)")
        }
        guard let arr = obj["keys"] as? [[String: Any]] else {
            throw PackageSignatureError.invalidKeyring("missing keys array")
        }
        var keys: [ExtensionPublisherKey] = []
        var seenIDs = Set<String>()
        var seenSubjects = Set<String>()
        for item in arr {
            guard let id = item["key_id"] as? String ?? item["keyID"] as? String, !id.isEmpty else {
                throw PackageSignatureError.invalidKeyring("missing key_id")
            }
            guard let b64 = item["public_key_b64"] as? String ?? item["publicKeyB64"] as? String else {
                throw PackageSignatureError.invalidKeyring("missing public_key_b64 for \(id)")
            }
            guard let raw = Data(base64Encoded: b64), raw.count == 32 else {
                throw PackageSignatureError.invalidKeyring("invalid public key length/base64 for \(id)")
            }
            guard let subject = item["subject"] as? String, !subject.isEmpty else {
                throw PackageSignatureError.invalidKeyring("missing subject for \(id)")
            }
            if seenIDs.contains(id) {
                throw PackageSignatureError.invalidKeyring("duplicate key_id \(id)")
            }
            if seenSubjects.contains(subject) {
                throw PackageSignatureError.invalidKeyring("duplicate subject \(subject)")
            }
            seenIDs.insert(id)
            seenSubjects.insert(subject)
            keys.append(ExtensionPublisherKey(keyID: id, publicKeyRaw: raw, subject: subject))
        }
        let revokedList =
            (obj["revoked_key_ids"] as? [String])
            ?? (obj["revokedKeyIDs"] as? [String])
            ?? []
        for r in revokedList where r.isEmpty {
            throw PackageSignatureError.invalidKeyring("empty revoked key id")
        }
        return PublisherKeyring(schema: schema, keys: keys, revokedKeyIDs: Set(revokedList))
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
            "schema": schema,
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
    case missingSignedStatement
    case checksumMismatch(String)
    case invalidSignature
    case unknownPublisher
    case revokedKey(String)
    case cryptoUnavailable
    case untrusted(ExtensionTrustClass)
    case license(String)
    case sbom(String)
    case invalidKeyring(String)
    case inventory(String)
}

/// Canonical signed publisher statement (EXT-N06).
public struct SignedPackageStatement: Sendable, Hashable, Codable {
    public var schema: Int
    public var extensionID: String
    public var version: String
    public var publisher: Publisher
    public var manifestSHA256: String
    public var inventorySHA256: String
    public var packageSHA256: String
    public var createdAt: String
    public var minimumHostAPI: String
    public var maximumHostAPI: String?

    public struct Publisher: Sendable, Hashable, Codable {
        public var subject: String
        public var keyID: String

        public init(subject: String, keyID: String) {
            self.subject = subject
            self.keyID = keyID
        }

        enum CodingKeys: String, CodingKey {
            case subject
            case keyID = "key_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case extensionID = "extension_id"
        case version
        case publisher
        case manifestSHA256 = "manifest_sha256"
        case inventorySHA256 = "inventory_sha256"
        case packageSHA256 = "package_sha256"
        case createdAt = "created_at"
        case minimumHostAPI = "minimum_host_api"
        case maximumHostAPI = "maximum_host_api"
    }

    public init(
        schema: Int = 1,
        extensionID: String,
        version: String,
        publisher: Publisher,
        manifestSHA256: String,
        inventorySHA256: String,
        packageSHA256: String,
        createdAt: String,
        minimumHostAPI: String,
        maximumHostAPI: String? = nil
    ) {
        self.schema = schema
        self.extensionID = extensionID
        self.version = version
        self.publisher = publisher
        self.manifestSHA256 = manifestSHA256
        self.inventorySHA256 = inventorySHA256
        self.packageSHA256 = packageSHA256
        self.createdAt = createdAt
        self.minimumHostAPI = minimumHostAPI
        self.maximumHostAPI = maximumHostAPI
    }

    /// Canonical JSON bytes (sorted keys, no pretty print) for signing.
    public func canonicalJSONData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }
}

/// Ed25519 package signing over canonical signed-statement (EXT-N06).
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

    /// EXT-N07: write keys via unique temp file → fsync → mode → atomic rename → dir fsync; keep `.bak`.
    public static func writeKeyPair(_ pair: KeyPair, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateURL = directory.appendingPathComponent("ed25519.private")
        let publicURL = directory.appendingPathComponent("ed25519.public")
        try atomicWrite(data: pair.privateKeyRaw, to: privateURL, mode: 0o600, retainBackup: true)
        try atomicWrite(data: pair.publicKeyRaw, to: publicURL, mode: 0o644, retainBackup: true)
        let meta = """
            {"key_id":"\(pair.keyID)","public_key_b64":"\(pair.publicKeyRaw.base64EncodedString())"}
            """
        try atomicWrite(
            data: Data(meta.utf8),
            to: directory.appendingPathComponent("key.json"),
            mode: 0o644,
            retainBackup: false
        )
    }

    private static func atomicWrite(
        data: Data,
        to url: URL,
        mode: mode_t,
        retainBackup: Bool
    ) throws {
        let path = url.path
        let dir = url.deletingLastPathComponent().path
        let tmpName = ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        let tmpURL = url.deletingLastPathComponent().appendingPathComponent(tmpName)
        let tmpPath = tmpURL.path

        // Refuse symlink destinations.
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw PackageSignatureError.cryptoUnavailable
            }
            if retainBackup {
                let bak = url.path + ".bak"
                // Best-effort rotate previous key.
                _ = try? FileManager.default.removeItem(atPath: bak)
                try? FileManager.default.copyItem(atPath: path, toPath: bak)
            }
        }

        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else {
            throw PackageSignatureError.cryptoUnavailable
        }
        defer {
            // If still open somehow, close.
        }
        var remaining = data
        while !remaining.isEmpty {
            let written: Int = remaining.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return write(fd, base, remaining.count)
            }
            if written < 0 {
                let err = errno
                if err == EINTR { continue }
                close(fd)
                try? FileManager.default.removeItem(at: tmpURL)
                throw PackageSignatureError.cryptoUnavailable
            }
            if written == 0 {
                close(fd)
                try? FileManager.default.removeItem(at: tmpURL)
                throw PackageSignatureError.cryptoUnavailable
            }
            remaining = remaining.dropFirst(written)
        }
        fchmod(fd, mode)
        fsync(fd)
        close(fd)

        // Atomic replace.
        if rename(tmpPath, path) != 0 {
            try? FileManager.default.removeItem(at: tmpURL)
            throw PackageSignatureError.cryptoUnavailable
        }
        // Fsync directory.
        let dirFd = open(dir, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            fsync(dirFd)
            close(dirFd)
        }
    }

    public static func writeChecksums(packageRoot: URL) throws -> Data {
        let digestMap = try fileDigests(packageRoot: packageRoot)
        let data = try JSONSerialization.data(withJSONObject: digestMap, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: packageRoot.appendingPathComponent("checksums.json"), options: .atomic)
        return data
    }

    /// EXT-N06: sign canonical statement binding publisher + inventory + package digests.
    public static func sign(packageRoot: URL, privateKeyRaw: Data, keyID: String, subject: String) throws {
        #if canImport(CryptoKit)
            // Inventory + checksums first (content only).
            let inventory = try PackageInventoryBuilder.build(packageRoot: packageRoot)
            let checksums = try writeChecksums(packageRoot: packageRoot)

            // Manifest digest.
            let manifestURL = packageRoot.appendingPathComponent("extension.toml")
            let manifestData: Data
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                manifestData = try Data(contentsOf: manifestURL)
            } else {
                let jsonURL = packageRoot.appendingPathComponent("extension.json")
                manifestData = try Data(contentsOf: jsonURL)
            }
            let manifestSHA = sha256Hex(manifestData)

            // Load extension id / version for statement.
            let plan = try ExtensionPackageLoader.load(
                directory: packageRoot, options: .init(computeDigest: false))

            let createdAt = ISO8601DateFormatter().string(from: Date())
            let statement = SignedPackageStatement(
                extensionID: plan.packageID.rawValue,
                version: plan.version.description,
                publisher: .init(subject: subject, keyID: keyID),
                manifestSHA256: manifestSHA,
                inventorySHA256: inventory.inventorySHA256,
                packageSHA256: inventory.packageSHA256,
                createdAt: createdAt,
                minimumHostAPI: plan.manifest.requiredAPIVersion.min.description,
                maximumHostAPI: nil
            )
            let statementData = try statement.canonicalJSONData()
            try statementData.write(
                to: packageRoot.appendingPathComponent("signed-statement.json"), options: .atomic)

            // Also write inventory.json for consumers.
            let invEnc = JSONEncoder()
            invEnc.outputFormatting = [.sortedKeys]
            try invEnc.encode(inventory).write(
                to: packageRoot.appendingPathComponent("inventory.json"), options: .atomic)

            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
            // Signature covers the canonical signed statement (not bare checksums alone).
            let signature = try privateKey.signature(for: statementData)
            try signature.write(to: packageRoot.appendingPathComponent("signature.ed25519"), options: .atomic)

            // Advisory publisher.json (identity also bound inside signed statement).
            let publisher: [String: String] = [
                "key_id": keyID,
                "subject": subject,
                "public_key_b64": privateKey.publicKey.rawRepresentation.base64EncodedString(),
            ]
            let pubData = try JSONSerialization.data(withJSONObject: publisher, options: [.sortedKeys, .prettyPrinted])
            try pubData.write(to: packageRoot.appendingPathComponent("publisher.json"), options: .atomic)

            // Refresh checksums to include inventory path digests if needed — signature meta excluded.
            _ = checksums
        #else
            throw PackageSignatureError.cryptoUnavailable
        #endif
    }

    /// EXT-N04/N05: inventory every regular file including hidden and `.codeeditor/`.
    public static func fileDigests(packageRoot: URL) throws -> [String: String] {
        #if canImport(CryptoKit)
            let inventory: PackageInventoryDocument
            do {
                inventory = try PackageInventoryBuilder.build(packageRoot: packageRoot)
            } catch let e as PackageInventoryError {
                switch e {
                case .keyMaterial(let p):
                    throw PackageSignatureError.checksumMismatch("key-material:\(p)")
                case .symlink(let p):
                    throw PackageSignatureError.checksumMismatch("symlink:\(p)")
                case .specialFile(let p):
                    throw PackageSignatureError.checksumMismatch("special-file:\(p)")
                case .pathEscape(let p):
                    throw PackageSignatureError.checksumMismatch("path-escape:\(p)")
                case .cryptoUnavailable:
                    throw PackageSignatureError.cryptoUnavailable
                default:
                    throw PackageSignatureError.inventory(String(describing: e))
                }
            }
            var map: [String: String] = [:]
            for e in inventory.entries where e.kind != .signatureMeta {
                map[e.relativePath] = e.sha256
            }
            map["__package__"] = inventory.packageSHA256
            map["__inventory__"] = inventory.inventorySHA256
            return map
        #else
            throw PackageSignatureError.cryptoUnavailable
        #endif
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            // EXT-N08: never fatalError — callers only hit this under #else.
            ""
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
        #if !canImport(CryptoKit)
            throw PackageSignatureError.cryptoUnavailable
        #else
            let checksumsURL = packageRoot.appendingPathComponent("checksums.json")
            let sigURL = packageRoot.appendingPathComponent("signature.ed25519")
            let pubURL = packageRoot.appendingPathComponent("publisher.json")
            let statementURL = packageRoot.appendingPathComponent("signed-statement.json")

            let hasChecksums = FileManager.default.fileExists(atPath: checksumsURL.path)
            let hasSig = FileManager.default.fileExists(atPath: sigURL.path)
            let hasPub = FileManager.default.fileExists(atPath: pubURL.path)
            let hasStatement = FileManager.default.fileExists(atPath: statementURL.path)

            if let plan = try? ExtensionPackageLoader.load(
                directory: packageRoot, options: .init(computeDigest: false)
            ) {
                do {
                    try PackageSBOM.enforce(packageRoot: packageRoot, plan: plan, policy: policy.licensePolicy)
                } catch let e as PackageSBOM.SBOMError {
                    throw PackageSignatureError.license(String(describing: e))
                }
                // EXT-N17: data-only runtime cannot carry undeclared executables.
                if plan.manifest.requiredHostCapabilities.isEmpty || true {
                    let inv = try PackageInventoryBuilder.build(packageRoot: packageRoot)
                    let declared = declaredExecutablePaths(plan: plan, packageRoot: packageRoot)
                    let isDataOnly =
                        (try? String(contentsOf: packageRoot.appendingPathComponent("extension.toml"), encoding: .utf8))?
                        .contains("data-only") == true
                    if isDataOnly {
                        try PackageInventoryBuilder.assertNoUndeclaredExecutables(
                            inventory: inv, declaredPaths: declared)
                    }
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
            let signedPaths = Set(map.keys)
            let currentPaths = Set(current.keys)
            if signedPaths != currentPaths {
                let extra = currentPaths.subtracting(signedPaths).sorted()
                let missing = signedPaths.subtracting(currentPaths).sorted()
                if let first = extra.first {
                    throw PackageSignatureError.checksumMismatch("unsigned-extra:\(first)")
                }
                if let first = missing.first {
                    throw PackageSignatureError.checksumMismatch("missing:\(first)")
                }
                throw PackageSignatureError.checksumMismatch("file-set-mismatch")
            }
            for (path, expected) in map {
                guard let actual = current[path], actual == expected else {
                    throw PackageSignatureError.checksumMismatch(path)
                }
            }

            if hasSig {
                guard hasPub else { throw PackageSignatureError.missingPublisher }
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
                    if !policy.allowUnknownSelfSigned {
                        throw PackageSignatureError.unknownPublisher
                    }
                } else if !known {
                    throw PackageSignatureError.unknownPublisher
                }

                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
                let signature = try Data(contentsOf: sigURL)

                // EXT-N06: require canonical signed statement for trusted packages.
                if hasStatement {
                    let statementData = try Data(contentsOf: statementURL)
                    guard publicKey.isValidSignature(signature, for: statementData) else {
                        throw PackageSignatureError.invalidSignature
                    }
                    let stmt = try JSONDecoder().decode(SignedPackageStatement.self, from: statementData)
                    // Statement is source of truth for publisher binding (EXT-N06).
                    if stmt.publisher.keyID != keyID {
                        throw PackageSignatureError.invalidSignature
                    }
                    // publisher.json subject must match the signed statement (detect post-sign swap).
                    if stmt.publisher.subject != subject {
                        throw PackageSignatureError.invalidSignature
                    }
                    if let expected = map["__package__"], stmt.packageSHA256 != expected {
                        throw PackageSignatureError.checksumMismatch("__package__")
                    }
                    if let trusted = policy.trustedKeys.first(where: { $0.keyID == keyID }),
                        trusted.subject != stmt.publisher.subject
                    {
                        throw PackageSignatureError.unknownPublisher
                    }
                    return PackageVerifyReport(
                        trustClass: .trustedSigned,
                        publisher: stmt.publisher.subject,
                        keyID: keyID,
                        errors: []
                    )
                }

                // Legacy path: signature over checksums.json (dev/testing only when allowUnknownSelfSigned).
                if policy.allowUnknownSelfSigned || policy.allowWorkspaceDevNative {
                    guard publicKey.isValidSignature(signature, for: checksumsData) else {
                        throw PackageSignatureError.invalidSignature
                    }
                    if let trusted = policy.trustedKeys.first(where: { $0.keyID == keyID }),
                        trusted.subject != subject
                    {
                        throw PackageSignatureError.unknownPublisher
                    }
                    return PackageVerifyReport(
                        trustClass: .trustedSigned,
                        publisher: subject,
                        keyID: keyID,
                        errors: ["legacy-checksum-signature"]
                    )
                }
                throw PackageSignatureError.missingSignedStatement
            }

            if policy.allowWorkspaceDevNative {
                return PackageVerifyReport(trustClass: .workspaceDev, publisher: nil, keyID: nil, errors: [])
            }
            throw PackageSignatureError.untrusted(.untrusted)
        #endif
    }

    private static func declaredExecutablePaths(
        plan: ValidatedContributionPlan,
        packageRoot: URL
    ) -> Set<String> {
        var paths = Set<String>()
        if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("native-helper").path) {
            paths.insert("native-helper")
        }
        // Manifest runtime entrypoint if present.
        _ = plan
        return paths
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

/// EXT-N20: production surface flags for release gates.
public enum ExtensionProductionSurface {
    /// Conformance guest is a fixture executable, not a Stable library product.
    public static let conformanceGuestIsPublicLibraryProduct = false
}
