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
        profile: String = "codeeditor-swift-first-2026",
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

    /// Honest pre-alpha default (REL-N01). Features are experimental unless unsupported.
    public static let phase13Default: CompatibilityProfile = {
        var features: [String: CompatibilityFeatureStatus] = [:]
        features["languages"] = .experimental
        features["themes"] = .experimental
        features["icon_themes"] = .experimental
        features["snippets"] = .experimental
        features["language_servers"] = .experimental
        features["completion_labels"] = .experimental
        features["symbol_labels"] = .experimental
        features["debug_adapters"] = .experimental
        features["debug_locators"] = .experimental
        features["mcp_servers"] = .experimental
        features["process_exec"] = .experimental
        features["download_file"] = .experimental
        features["npm_install"] = .experimental
        features["worktree"] = .experimental
        features["project"] = .experimental
        features["settings"] = .experimental
        features["kv_store"] = .experimental
        features["documentation_indexing"] = .experimental
        features["slash_commands"] = .experimental
        features["language_model_provider_metadata"] = .unsupported
        features["legacy_agent_server_hosting"] = .unsupported
        return CompatibilityProfile(
            profile: "codeeditor-swift-first-2026",
            upstreamCommit: "unpinned",
            features: features
        )
    }()

    /// Alias for current defaults (pre-alpha; not an RC claim).
    public static let phase16Default: CompatibilityProfile = .phase13Default

    /// Load the repository honesty profile when present.
    public static var repositoryDefault: CompatibilityProfile { .phase13Default }
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
