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

/// Content-based executable classification (magic bytes + mode), not path-extension alone (EXT-N17).
public enum PackageExecutableClassifier {
    /// Wasm binary magic `\0asm`.
    public static let wasmMagic = Data([0x00, 0x61, 0x73, 0x6D])
    /// Mach-O 64-bit magic (little-endian `0xFEEDFACF`).
    public static let macho64LE = Data([0xCF, 0xFA, 0xED, 0xFE])
    /// Mach-O 32-bit magic.
    public static let macho32LE = Data([0xCE, 0xFA, 0xED, 0xFE])
    /// Mach-O fat / universal.
    public static let machoFatLE = Data([0xCA, 0xFE, 0xBA, 0xBE])
    /// ELF magic.
    public static let elfMagic = Data([0x7F, 0x45, 0x4C, 0x46])
    /// PE/COFF `MZ`.
    public static let peMagic = Data([0x4D, 0x5A])

    /// Classify by header magic, optional Unix execute bits, and declared path membership.
    public static func classify(
        relativePath: String,
        header: Data,
        isMeta: Bool,
        declaredExecutable: Bool,
        unixExecutable: Bool
    ) -> PackageContentKind {
        if isMeta { return .signatureMeta }
        if relativePath == "extension.toml" || relativePath == "extension.json" {
            return .manifest
        }
        if header.starts(with: wasmMagic) {
            return .wasm
        }
        if header.starts(with: macho64LE) || header.starts(with: macho32LE)
            || header.starts(with: machoFatLE) || header.starts(with: elfMagic)
            || header.starts(with: peMagic)
        {
            return .nativeExecutable
        }
        // Shebang scripts.
        if header.starts(with: Data([0x23, 0x21])) {  // #!
            return .script
        }
        if declaredExecutable || unixExecutable {
            return .nativeExecutable
        }
        // Extension hints only as secondary signal after magic inspection.
        let lower = relativePath.lowercased()
        if lower.hasSuffix(".wasm") { return .wasm }
        if lower.hasSuffix(".dylib") || lower.hasSuffix(".so") || lower.hasSuffix(".dll") {
            return .nativeExecutable
        }
        if lower.hasSuffix(".sh") || lower.hasSuffix(".command") || lower.hasSuffix(".bash") {
            return .script
        }
        let base = (relativePath as NSString).lastPathComponent.lowercased()
        if base == "native-helper" { return .nativeExecutable }
        return .data
    }

    public static func readHeader(of url: URL, maxBytes: Int = 16) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    public static func hasUnixExecuteBit(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let perms = attrs[.posixPermissions] as? NSNumber
        else { return false }
        let mode = perms.uint16Value
        return (mode & 0o111) != 0
    }
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
                let header = try PackageExecutableClassifier.readHeader(of: url)
                let kind = PackageExecutableClassifier.classify(
                    relativePath: rel,
                    header: header,
                    isMeta: isMeta,
                    declaredExecutable: declaredExecutablePaths.contains(rel),
                    unixExecutable: PackageExecutableClassifier.hasUnixExecuteBit(at: url)
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
            // EXT-N10: stream file bytes — never whole-file Data(contentsOf:).
            var packageHasher = SHA256()
            for e in entries where e.kind != .signatureMeta {
                packageHasher.update(data: Data(e.relativePath.utf8))
                packageHasher.update(data: Data([0]))
                let url = root.appendingPathComponent(e.relativePath)
                try streamIntoHasher(url: url, hasher: &packageHasher)
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

    /// Declared executable paths from a validated plan + package layout (EXT-N17).
    /// Binds runtime entrypoint, native-helper, and explicit inventory declarations — not heuristics alone.
    public static func declaredExecutablePaths(
        runtimeKind: String?,
        runtimeEntrypoint: String?,
        packageRoot: URL,
        additionalDeclared: Set<String> = []
    ) -> Set<String> {
        var paths = additionalDeclared
        if let ep = runtimeEntrypoint, !ep.isEmpty {
            paths.insert(ep)
        }
        let nativeHelper = packageRoot.appendingPathComponent("native-helper")
        if FileManager.default.fileExists(atPath: nativeHelper.path) {
            paths.insert("native-helper")
        }
        // Non-data-only runtimes that name a wasm entrypoint.
        if let kind = runtimeKind?.lowercased(),
            kind.contains("wasm") || kind == "swift-wasm" || kind == "native"
        {
            if let ep = runtimeEntrypoint { paths.insert(ep) }
        }
        return paths
    }

    // MARK: - Helpers

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

        private static func streamIntoHasher(url: URL, hasher: inout SHA256) throws {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
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
