import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

// MARK: - Inventory limits (EXT-N10)

/// Hard resource limits for package inventory (fail closed before hashing/parsing).
public struct PackageInventoryLimits: Sendable, Hashable, Codable {
    public var maxFileCount: Int
    public var maxDirectoryDepth: Int
    public var maxFileBytes: Int
    public var maxTotalBytes: Int
    public var maxPathLength: Int
    public var maxComponentLength: Int
    public var maxManifestBytes: Int

    public init(
        maxFileCount: Int = 10_000,
        maxDirectoryDepth: Int = 32,
        maxFileBytes: Int = 64 * 1024 * 1024,
        maxTotalBytes: Int = 256 * 1024 * 1024,
        maxPathLength: Int = 4_096,
        maxComponentLength: Int = 255,
        maxManifestBytes: Int = 256 * 1024
    ) {
        self.maxFileCount = maxFileCount
        self.maxDirectoryDepth = maxDirectoryDepth
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxPathLength = maxPathLength
        self.maxComponentLength = maxComponentLength
        self.maxManifestBytes = maxManifestBytes
    }

    public static let `default` = PackageInventoryLimits()
}

// MARK: - Content classification (EXT-N17)

/// Declared/detected package content kind. Executable kinds must appear in the signed inventory.
public enum PackageContentKind: String, Sendable, Hashable, Codable {
    case data
    case manifest
    case wasm
    case nativeExecutable
    case script
    case signatureMeta
}

// MARK: - Inventory entry

public struct PackageInventoryEntry: Sendable, Hashable, Codable {
    public var relativePath: String
    public var size: UInt64
    public var sha256: String
    public var kind: PackageContentKind

    public init(relativePath: String, size: UInt64, sha256: String, kind: PackageContentKind) {
        self.relativePath = relativePath
        self.size = size
        self.sha256 = sha256
        self.kind = kind
    }

    public var isExecutable: Bool {
        switch kind {
        case .wasm, .nativeExecutable, .script: return true
        case .data, .manifest, .signatureMeta: return false
        }
    }
}

// MARK: - Inventory document

public struct PackageInventoryDocument: Sendable, Hashable, Codable {
    public var schema: Int
    public var entries: [PackageInventoryEntry]
    /// Canonical SHA-256 over sorted path+digest+kind lines.
    public var inventorySHA256: String
    /// Package content digest (sorted path+bytes, excluding signature meta).
    public var packageSHA256: String

    public init(
        schema: Int = 1,
        entries: [PackageInventoryEntry],
        inventorySHA256: String,
        packageSHA256: String
    ) {
        self.schema = schema
        self.entries = entries
        self.inventorySHA256 = inventorySHA256
        self.packageSHA256 = packageSHA256
    }

    public var executableEntries: [PackageInventoryEntry] {
        entries.filter(\.isExecutable)
    }
}

// MARK: - Errors

public enum PackageInventoryError: Error, Sendable, Equatable {
    case cryptoUnavailable
    case tooManyFiles(Int)
    case directoryTooDeep(Int)
    case fileTooLarge(path: String, size: Int)
    case totalTooLarge(Int)
    case pathTooLong(String)
    case componentTooLong(String)
    case symlink(String)
    case specialFile(String)
    case pathEscape(String)
    case keyMaterial(String)
    case undeclaredExecutable(String)
    case streamingHashFailed(String)
    case cannotEnumerate
}

// MARK: - Detached signature / meta paths (unsigned by design)

/// Paths excluded from content inventory because they are detached signature artifacts.
public enum PackageSignatureMeta {
    public static let names: Set<String> = [
        "checksums.json",
        "signature.ed25519",
        "publisher.json",
        "signed-statement.json",
        "inventory.json",
        "sbom.spdx.json",
    ]

    public static func isMeta(_ relativePath: String) -> Bool {
        names.contains(relativePath)
    }
}

// MARK: - Inventory builder (EXT-N04, EXT-N05, EXT-N10)

/// Secure package inventory: includes **all** regular files including hidden ones and
/// `.codeeditor/` package content. Host-generated state must live outside the package root.
public enum PackageInventoryBuilder {
    /// Build a complete inventory with streaming SHA-256, global quotas, no symlink follow.
    public static func build(
        packageRoot: URL,
        limits: PackageInventoryLimits = .default,
        declaredExecutablePaths: Set<String> = []
    ) throws -> PackageInventoryDocument {
        #if !canImport(CryptoKit)
            throw PackageInventoryError.cryptoUnavailable
        #else
            let root = packageRoot.standardizedFileURL
            let fm = FileManager.default
            guard
                let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
                    ],
                    // EXT-N04: never skip hidden files — inventory every directory entry.
                    options: []
                )
            else {
                throw PackageInventoryError.cannotEnumerate
            }

            let rootPath = root.path
            var entries: [PackageInventoryEntry] = []
            var totalBytes = 0
            var fileCount = 0

            // Preflight key-material at package root.
            for banned in ["ed25519.private", "ed25519.public"] {
                if fm.fileExists(atPath: root.appendingPathComponent(banned).path) {
                    throw PackageInventoryError.keyMaterial(banned)
                }
            }
            if fm.fileExists(atPath: root.appendingPathComponent("keys", isDirectory: true).path) {
                throw PackageInventoryError.keyMaterial("keys/")
            }

            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
                ])
                let filePath = url.standardizedFileURL.path
                guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
                    throw PackageInventoryError.pathEscape(filePath)
                }
                var rel = String(filePath.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if rel.isEmpty { continue }

                // Depth = number of path components.
                let components = rel.split(separator: "/").map(String.init)
                if components.count > limits.maxDirectoryDepth {
                    throw PackageInventoryError.directoryTooDeep(components.count)
                }
                if rel.count > limits.maxPathLength {
                    throw PackageInventoryError.pathTooLong(rel)
                }
                for c in components {
                    if c.count > limits.maxComponentLength {
                        throw PackageInventoryError.componentTooLong(c)
                    }
                }

                if values.isSymbolicLink == true {
                    throw PackageInventoryError.symlink(rel)
                }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else {
                    throw PackageInventoryError.specialFile(rel)
                }

                // Detached signature meta is listed as signatureMeta but not part of package digest.
                let isMeta = PackageSignatureMeta.isMeta(rel)

                if rel.hasPrefix("keys/") || rel == "ed25519.private" || rel == "ed25519.public"
                    || rel.contains("/keys/")
                {
                    throw PackageInventoryError.keyMaterial(rel)
                }

                let size = Int(values.fileSize ?? 0)
                if size > limits.maxFileBytes {
                    throw PackageInventoryError.fileTooLarge(path: rel, size: size)
                }
                totalBytes += size
                if totalBytes > limits.maxTotalBytes {
                    throw PackageInventoryError.totalTooLarge(totalBytes)
                }
                fileCount += 1
                if fileCount > limits.maxFileCount {
                    throw PackageInventoryError.tooManyFiles(fileCount)
                }

                let digest = try streamSHA256(of: url)
                let kind = classify(
                    relativePath: rel,
                    isMeta: isMeta,
                    declaredExecutable: declaredExecutablePaths.contains(rel)
                )
                entries.append(
                    PackageInventoryEntry(
                        relativePath: rel,
                        size: UInt64(size),
                        sha256: digest,
                        kind: kind
                    ))
            }

            entries.sort { $0.relativePath < $1.relativePath }

            // Package digest: content files only (exclude signature meta).
            var packageHasher = SHA256()
            for e in entries where e.kind != .signatureMeta {
                packageHasher.update(data: Data(e.relativePath.utf8))
                packageHasher.update(data: Data([0]))
                // Re-stream content for package digest binding path+bytes.
                let url = root.appendingPathComponent(e.relativePath)
                packageHasher.update(data: try Data(contentsOf: url))
                packageHasher.update(data: Data([0]))
            }
            let packageSHA256 = hex(packageHasher.finalize())

            // Inventory digest over content entries only (signature meta is detached).
            var invHasher = SHA256()
            for e in entries where e.kind != .signatureMeta {
                let line = "\(e.relativePath)|\(e.sha256)|\(e.kind.rawValue)|\(e.size)\n"
                invHasher.update(data: Data(line.utf8))
            }
            let inventorySHA256 = hex(invHasher.finalize())

            return PackageInventoryDocument(
                schema: 1,
                entries: entries,
                inventorySHA256: inventorySHA256,
                packageSHA256: packageSHA256
            )
        #endif
    }

    /// Fail closed when inventory contains executable kinds not declared by the signed manifest.
    public static func assertNoUndeclaredExecutables(
        inventory: PackageInventoryDocument,
        declaredPaths: Set<String>
    ) throws {
        for e in inventory.entries where e.isExecutable {
            if !declaredPaths.contains(e.relativePath) {
                throw PackageInventoryError.undeclaredExecutable(e.relativePath)
            }
        }
    }

    // MARK: - Helpers

    private static func classify(
        relativePath: String,
        isMeta: Bool,
        declaredExecutable: Bool
    ) -> PackageContentKind {
        if isMeta { return .signatureMeta }
        if relativePath == "extension.toml" || relativePath == "extension.json" {
            return .manifest
        }
        let lower = relativePath.lowercased()
        if lower.hasSuffix(".wasm") { return .wasm }
        if declaredExecutable { return .nativeExecutable }
        // Executable bit / known helper names
        let base = (relativePath as NSString).lastPathComponent.lowercased()
        if base == "native-helper" || base.hasSuffix(".dylib") || base.hasSuffix(".so")
            || base.hasSuffix(".dll")
        {
            return .nativeExecutable
        }
        if lower.hasSuffix(".sh") || lower.hasSuffix(".command") || lower.hasSuffix(".bash") {
            return .script
        }
        return .data
    }

    #if canImport(CryptoKit)
        private static func streamSHA256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize())
        }

        private static func hex(_ digest: SHA256Digest) -> String {
            digest.map { String(format: "%02x", $0) }.joined()
        }
    #endif
}

// MARK: - Compatibility levels S0–S4 (EXT-N02)

/// Package/feature compatibility level with required evidence.
public enum ExtensionCompatibilityLevel: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Package layout/manifest parses.
    case s0PackageSyntax = "S0"
    /// Themes/icons/snippets/grammars/query assets behave equivalently.
    case s1DataContributions = "S1"
    /// CodeEditor Swift API can express the target capability.
    case s2SwiftSDKParity = "S2"
    /// Host behavior matches documented fixtures.
    case s3BehavioralParity = "S3"
    /// Install/update/revoke/crash/security/performance qualified.
    case s4OperationalParity = "S4"

    public static func < (lhs: ExtensionCompatibilityLevel, rhs: ExtensionCompatibilityLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    public var rank: Int {
        switch self {
        case .s0PackageSyntax: return 0
        case .s1DataContributions: return 1
        case .s2SwiftSDKParity: return 2
        case .s3BehavioralParity: return 3
        case .s4OperationalParity: return 4
        }
    }

    public var title: String {
        switch self {
        case .s0PackageSyntax: return "Package syntax"
        case .s1DataContributions: return "Data contributions"
        case .s2SwiftSDKParity: return "Swift SDK parity"
        case .s3BehavioralParity: return "Behavioral parity"
        case .s4OperationalParity: return "Operational parity"
        }
    }
}

/// Per-feature compatibility claim with evidence pointers (not a single boolean).
public struct ExtensionFeatureCompatibility: Sendable, Hashable, Codable {
    public var feature: String
    public var level: ExtensionCompatibilityLevel
    public var evidenceTests: [String]
    public var notes: String?

    public init(
        feature: String,
        level: ExtensionCompatibilityLevel,
        evidenceTests: [String] = [],
        notes: String? = nil
    ) {
        self.feature = feature
        self.level = level
        self.evidenceTests = evidenceTests
        self.notes = notes
    }
}

/// Honest multi-level compatibility report (EXT-N02). Zed binary compatibility is separate and not claimed.
public struct ExtensionCompatibilityReport: Sendable, Hashable, Codable {
    public var profile: String
    public var features: [ExtensionFeatureCompatibility]
    /// Always false until an explicit Zed binary program exists.
    public var zedBinaryCompatibility: Bool

    public init(
        profile: String = "codeeditor-swift-first-2026",
        features: [ExtensionFeatureCompatibility] = [],
        zedBinaryCompatibility: Bool = false
    ) {
        self.profile = profile
        self.features = features
        self.zedBinaryCompatibility = zedBinaryCompatibility
    }

    public func level(for feature: String) -> ExtensionCompatibilityLevel? {
        features.first { $0.feature == feature }?.level
    }

    /// Default pre-alpha report: data features at S1 experimental evidence; operational at S0.
    public static let preAlphaDefault: ExtensionCompatibilityReport = {
        let features: [ExtensionFeatureCompatibility] = [
            .init(feature: "package_syntax", level: .s0PackageSyntax, evidenceTests: ["test_EXT_N02_compatibilityLevels"]),
            .init(feature: "themes", level: .s1DataContributions, evidenceTests: ["test_EXT_N02_compatibilityLevels"]),
            .init(feature: "snippets", level: .s1DataContributions, evidenceTests: ["test_EXT_N02_compatibilityLevels"]),
            .init(feature: "grammars", level: .s1DataContributions, evidenceTests: ["test_EXT_N02_compatibilityLevels"]),
            .init(feature: "install_lifecycle", level: .s0PackageSyntax, evidenceTests: ["test_EXT_N02_compatibilityLevels"]),
            .init(
                feature: "zed_binary",
                level: .s0PackageSyntax,
                evidenceTests: [],
                notes: "Zed binary compatibility is not promised"
            ),
        ]
        return ExtensionCompatibilityReport(features: features, zedBinaryCompatibility: false)
    }()
}
