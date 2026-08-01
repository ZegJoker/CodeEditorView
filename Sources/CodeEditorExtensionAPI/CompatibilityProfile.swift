import Foundation

/// Feature classification per plan §6.3.
public enum CompatibilityFeatureStatus: String, Sendable, Hashable, Codable {
    case stable
    case compatibility
    case experimental
    case deprecated
    case unsupported
    case registryReplacement = "registry-replacement"
}

public enum CompatibilityFeatureKey: String, Sendable, Hashable, Codable, CaseIterable {
    case languages
    case themes
    case iconThemes = "icon_themes"
    case snippets
    case languageServers = "language_servers"
    case completionLabels = "completion_labels"
    case symbolLabels = "symbol_labels"
    case debugAdapters = "debug_adapters"
    case debugLocators = "debug_locators"
    case mcpServers = "mcp_servers"
    case processExec = "process_exec"
    case downloadFile = "download_file"
    case npmInstall = "npm_install"
    case worktree
    case project
    case settings
    case kvStore = "kv_store"
    case documentationIndexing = "documentation_indexing"
    case slashCommands = "slash_commands"
    case languageModelProviderMetadata = "language_model_provider_metadata"
    case legacyAgentServerHosting = "legacy_agent_server_hosting"
}

public struct CompatibilityProfile: Sendable, Hashable, Codable {
    public var profile: String
    public var upstreamCommit: String
    public var manifestSchema: Int
    public var swiftExtensionAPI: String
    public var features: [String: CompatibilityFeatureStatus]

    public init(
        profile: String = "zed-style-2026-07",
        upstreamCommit: String = "unpinned",
        manifestSchema: Int = 1,
        swiftExtensionAPI: String = "1.0",
        features: [String: CompatibilityFeatureStatus] = [:]
    ) {
        self.profile = profile
        self.upstreamCommit = upstreamCommit
        self.manifestSchema = manifestSchema
        self.swiftExtensionAPI = swiftExtensionAPI
        self.features = features
    }

    public func status(for key: CompatibilityFeatureKey) -> CompatibilityFeatureStatus {
        features[key.rawValue] ?? .unsupported
    }

    public func status(forRaw key: String) -> CompatibilityFeatureStatus {
        features[key] ?? .unsupported
    }

    /// Phase 13 default profile reflecting implemented surfaces.
    public static let phase13Default: CompatibilityProfile = {
        var features: [String: CompatibilityFeatureStatus] = [:]
        features["languages"] = .stable
        features["themes"] = .stable
        features["icon_themes"] = .stable
        features["snippets"] = .stable
        features["language_servers"] = .stable
        features["completion_labels"] = .stable
        features["symbol_labels"] = .stable
        features["debug_adapters"] = .stable
        features["debug_locators"] = .stable
        features["mcp_servers"] = .stable
        features["process_exec"] = .stable
        features["download_file"] = .stable
        features["npm_install"] = .stable
        features["worktree"] = .stable
        features["project"] = .stable
        features["settings"] = .stable
        features["kv_store"] = .stable
        features["documentation_indexing"] = .stable
        features["slash_commands"] = .compatibility
        features["language_model_provider_metadata"] = .experimental
        features["legacy_agent_server_hosting"] = .unsupported
        return CompatibilityProfile(
            profile: "zed-style-2026-07",
            upstreamCommit: "phase-13",
            features: features
        )
    }()
}

public enum CompatibilityProfileLoader {
    /// Load from TOML text (`[features]` table of string values).
    public static func load(toml: String) throws -> CompatibilityProfile {
        var profile = CompatibilityProfile.phase13Default
        var inFeatures = false
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inFeatures = line == "[features]"
                continue
            }
            if line.hasPrefix("profile") {
                if let v = parseStringValue(line) { profile.profile = v }
            } else if line.hasPrefix("upstream_commit") {
                if let v = parseStringValue(line) { profile.upstreamCommit = v }
            } else if line.hasPrefix("manifest_schema") {
                if let n = parseIntValue(line) { profile.manifestSchema = n }
            } else if line.hasPrefix("swift_extension_api") {
                if let v = parseStringValue(line) { profile.swiftExtensionAPI = v }
            } else if inFeatures, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let status = CompatibilityFeatureStatus(rawValue: val) {
                    profile.features[key] = status
                }
            }
        }
        return profile
    }

    public static func load(url: URL) throws -> CompatibilityProfile {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try load(toml: text)
    }

    private static func parseStringValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") { v.removeFirst() }
        if let hash = v.firstIndex(of: "#") {
            v = v[..<hash].trimmingCharacters(in: .whitespaces)
        }
        if v.hasSuffix("\"") { v.removeLast() }
        return String(v)
    }

    private static func parseIntValue(_ line: String) -> Int? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return Int(v.split(separator: " ").first.map(String.init) ?? "")
    }
}
