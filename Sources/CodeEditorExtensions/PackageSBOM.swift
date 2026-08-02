import CodeEditorExtensionAPI
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Minimal SPDX 2.3 JSON SBOM for extension packages.
public enum PackageSBOM {
    public struct Document: Sendable, Hashable, Codable {
        public var spdxVersion: String
        public var dataLicense: String
        public var spdxId: String
        public var name: String
        public var documentNamespace: String
        public var creationInfo: CreationInfo
        public var packages: [Package]
        public var files: [File]

        private enum CodingKeys: String, CodingKey {
            case spdxVersion, dataLicense, name, documentNamespace, creationInfo, packages, files
            case spdxId = "SPDXID"
        }

        public init(
            spdxVersion: String = "SPDX-2.3",
            dataLicense: String = "CC0-1.0",
            spdxId: String = "SPDXRef-DOCUMENT",
            name: String,
            documentNamespace: String,
            creationInfo: CreationInfo,
            packages: [Package],
            files: [File]
        ) {
            self.spdxVersion = spdxVersion
            self.dataLicense = dataLicense
            self.spdxId = spdxId
            self.name = name
            self.documentNamespace = documentNamespace
            self.creationInfo = creationInfo
            self.packages = packages
            self.files = files
        }
    }

    public struct CreationInfo: Sendable, Hashable, Codable {
        public var created: String
        public var creators: [String]
    }

    public struct Package: Sendable, Hashable, Codable {
        public var spdxId: String
        public var name: String
        public var versionInfo: String
        public var downloadLocation: String
        public var licenseConcluded: String
        public var licenseDeclared: String
        public var copyrightText: String

        private enum CodingKeys: String, CodingKey {
            case name, versionInfo, downloadLocation, licenseConcluded, licenseDeclared, copyrightText
            case spdxId = "SPDXID"
        }
    }

    public struct File: Sendable, Hashable, Codable {
        public var spdxId: String
        public var fileName: String
        public var checksums: [Checksum]

        private enum CodingKeys: String, CodingKey {
            case fileName, checksums
            case spdxId = "SPDXID"
        }
    }

    public struct Checksum: Sendable, Hashable, Codable {
        public var algorithm: String
        public var checksumValue: String
    }

    public struct LicensePolicy: Sendable {
        public var requireLicense: Bool
        public var requireSBOM: Bool
        public var allowedLicenses: Set<String>

        public init(
            requireLicense: Bool = false,
            requireSBOM: Bool = false,
            allowedLicenses: Set<String> = [
                "MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "ISC", "CC0-1.0", "Unlicense",
            ]
        ) {
            self.requireLicense = requireLicense
            self.requireSBOM = requireSBOM
            self.allowedLicenses = allowedLicenses
        }

        public static let permissive = LicensePolicy()
        public static let strict = LicensePolicy(requireLicense: true, requireSBOM: true)
    }

    public enum SBOMError: Error, Sendable, Equatable {
        case missingLicense
        case disallowedLicense(String)
        case missingSBOM
        case invalidSBOM(String)
    }

    public static func generate(packageRoot: URL, plan: ValidatedContributionPlan) throws -> Document {
        let license = declaredLicense(packageRoot: packageRoot, plan: plan) ?? "NOASSERTION"
        var files: [File] = []
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: packageRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw SBOMError.invalidSBOM("cannot enumerate package")
        }
        var index = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            var rel = url.path.replacingOccurrences(of: packageRoot.path, with: "")
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.hasPrefix(".") { continue }
            if rel == "sbom.spdx.json" { continue }
            index += 1
            let data = try Data(contentsOf: url)
            files.append(
                File(
                    spdxId: "SPDXRef-File-\(index)",
                    fileName: rel,
                    checksums: [Checksum(algorithm: "SHA256", checksumValue: sha256Hex(data))]
                ))
        }
        files.sort { $0.fileName < $1.fileName }
        let created = ISO8601DateFormatter().string(from: Date())
        return Document(
            name: "\(plan.packageID.rawValue)-\(plan.version)",
            documentNamespace: "https://codeeditor.local/spdx/\(plan.packageID.rawValue)/\(plan.version)",
            creationInfo: CreationInfo(
                created: created,
                creators: ["Tool: codeeditor-extension", "Organization: CodeEditorView"]
            ),
            packages: [
                Package(
                    spdxId: "SPDXRef-Package",
                    name: plan.packageID.rawValue,
                    versionInfo: plan.version.description,
                    downloadLocation: "NOASSERTION",
                    licenseConcluded: license,
                    licenseDeclared: license,
                    copyrightText: "NOASSERTION"
                )
            ],
            files: files
        )
    }

    public static func write(packageRoot: URL, plan: ValidatedContributionPlan) throws -> URL {
        let doc = try generate(packageRoot: packageRoot, plan: plan)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(doc)
        let url = packageRoot.appendingPathComponent("sbom.spdx.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func load(packageRoot: URL) throws -> Document {
        let url = packageRoot.appendingPathComponent("sbom.spdx.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SBOMError.missingSBOM
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw SBOMError.invalidSBOM(String(describing: error))
        }
    }

    public static func enforce(packageRoot: URL, plan: ValidatedContributionPlan, policy: LicensePolicy) throws {
        let license = declaredLicense(packageRoot: packageRoot, plan: plan)
        if policy.requireLicense {
            guard let license, license != "NOASSERTION", !license.isEmpty else {
                throw SBOMError.missingLicense
            }
            if !policy.allowedLicenses.contains(license) {
                throw SBOMError.disallowedLicense(license)
            }
        } else if let license, license != "NOASSERTION", !policy.allowedLicenses.contains(license),
            !policy.allowedLicenses.isEmpty
        {
            throw SBOMError.disallowedLicense(license)
        }
        if policy.requireSBOM {
            _ = try load(packageRoot: packageRoot)
        }
    }

    public static func declaredLicense(packageRoot: URL, plan: ValidatedContributionPlan) -> String? {
        _ = plan
        // Prefer LICENSE file first line; fall back to extension.toml `license =` field.
        let candidates = ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]
        for name in candidates {
            let url = packageRoot.appendingPathComponent(name)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let first =
                    text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                if first.uppercased().contains("MIT") { return "MIT" }
                if first.uppercased().contains("APACHE") { return "Apache-2.0" }
                if !first.isEmpty { return first }
            }
        }
        // extension.toml license field
        if let toml = try? String(contentsOf: packageRoot.appendingPathComponent("extension.toml"), encoding: .utf8) {
            for line in toml.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("license") {
                    let parts = t.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
            }
        }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            // EXT-006: never fall back to a non-cryptographic digest (length is not a hash).
            fatalError("CryptoKit unavailable: package SBOM digests require SHA-256 (fail closed)")
        #endif
    }
}
