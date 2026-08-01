import Foundation

/// Diagnostic from package validation.
public struct ExtensionPackageDiagnostic: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable {
        case error
        case warning
        case note
    }

    public var code: String
    public var severity: Severity
    public var message: String
    public var path: String?

    public init(code: String, severity: Severity, message: String, path: String? = nil) {
        self.code = code
        self.severity = severity
        self.message = message
        self.path = path
    }
}

/// Parsed `extension.toml` schema v1 (subset).
public struct ExtensionTOMLManifest: Sendable, Hashable {
    public var id: String
    public var name: String
    public var description: String?
    public var version: String
    public var schemaVersion: Int
    public var apiVersion: String
    public var authors: [String]
    public var repository: String?
    public var license: String?
    public var activationEvents: [String]
    public var runtimeKind: String?
    public var runtimeEntrypoint: String?
    public var capabilities: [String]
    public var permissions: [String]
    public var languageServers: [LanguageServerContribution]
    public var unsupportedFields: [String]

    public init(
        id: String,
        name: String,
        description: String? = nil,
        version: String = "1.0.0",
        schemaVersion: Int = 1,
        apiVersion: String = "1.0",
        authors: [String] = [],
        repository: String? = nil,
        license: String? = nil,
        activationEvents: [String] = ["startup"],
        runtimeKind: String? = nil,
        runtimeEntrypoint: String? = nil,
        capabilities: [String] = [],
        permissions: [String] = [],
        languageServers: [LanguageServerContribution] = [],
        unsupportedFields: [String] = []
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.schemaVersion = schemaVersion
        self.apiVersion = apiVersion
        self.authors = authors
        self.repository = repository
        self.license = license
        self.activationEvents = activationEvents
        self.runtimeKind = runtimeKind
        self.runtimeEntrypoint = runtimeEntrypoint
        self.capabilities = capabilities
        self.permissions = permissions
        self.languageServers = languageServers
        self.unsupportedFields = unsupportedFields
    }

    public func toExtensionManifest() throws -> ExtensionManifest {
        guard let semver = SemanticVersion.parse(version) else {
            throw ExtensionError.dataLoad("invalid version: \(version)")
        }
        let apiMin = SemanticVersion.parse(apiVersion) ?? .phase9API
        let events = activationEvents.compactMap(Self.parseActivationEvent)
        let caps = Set(capabilities.compactMap { HostCapability(rawValue: $0) })
        let perms = Set(permissions.compactMap { ExtensionPermission(rawValue: $0) })
        return ExtensionManifest(
            id: ExtensionID(rawValue: id),
            displayName: name,
            version: semver,
            requiredAPIVersion: .from(apiMin),
            activationEvents: events.isEmpty ? [.startup] : events,
            requiredHostCapabilities: caps,
            requestedPermissions: perms
        )
    }

    public static func parseActivationEvent(_ raw: String) -> ExtensionActivationEvent? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "startup" { return .startup }
        if s == "workspaceOpened" { return .workspaceOpened }
        if s == "manual" { return .manual }
        if s.hasPrefix("language:") {
            return .language(String(s.dropFirst("language:".count)))
        }
        if s.hasPrefix("command:") {
            return .command(String(s.dropFirst("command:".count)))
        }
        if s.hasPrefix("fileMatch:") {
            return .fileMatch(pattern: String(s.dropFirst("fileMatch:".count)))
        }
        if s.hasPrefix("view:") {
            return .view(String(s.dropFirst("view:".count)))
        }
        return nil
    }
}

/// Minimal TOML subset parser for extension manifests (no external dependency).
public enum ExtensionTOMLParser {
    public static let maxManifestBytes = 256 * 1024

    public static func parse(string: String) throws -> (manifest: ExtensionTOMLManifest, diagnostics: [ExtensionPackageDiagnostic]) {
        var diagnostics: [ExtensionPackageDiagnostic] = []
        let data = Data(string.utf8)
        if data.count > maxManifestBytes {
            throw ExtensionError.dataLoad("manifest exceeds \(maxManifestBytes) bytes")
        }

        var root: [String: TOMLValue] = [:]
        var section = ""
        var arrayTables: [String: [[String: TOMLValue]]] = [:]

        for (lineNumber, rawLine) in string.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                // crude: ignore comments not in strings
                if !line[..<hash].contains("\"") {
                    line = String(line[..<hash])
                }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                section = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                arrayTables[section, default: []].append([:])
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if root[section] == nil {
                    root[section] = .table([:])
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                diagnostics.append(.init(
                    code: "toml.bad_line",
                    severity: .warning,
                    message: "unparsed line \(lineNumber + 1)"
                ))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let valueRaw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let value = parseValue(String(valueRaw))

            if section.hasPrefix("[[") {
                // handled via arrayTables path
            } else if let last = arrayTables[section], !last.isEmpty, !section.isEmpty {
                var table = last[last.count - 1]
                table[key] = value
                arrayTables[section]?[last.count - 1] = table
            } else if section.isEmpty {
                root[key] = value
            } else if case .table(var table) = root[section] {
                table[key] = value
                root[section] = .table(table)
            } else {
                root[section] = .table([key: value])
            }
        }

        // Known unsupported keys for parity reporting
        let knownRoot = Set([
            "id", "name", "description", "version", "schema_version", "api_version",
            "authors", "repository", "license",
        ])
        let unsupported = root.keys.filter {
            !knownRoot.contains($0)
                && $0 != "activation" && $0 != "runtime" && $0 != "capabilities"
                && $0 != "permissions" && $0 != "contributions"
                && !$0.hasPrefix("language_servers")
        }
        for u in unsupported {
            diagnostics.append(.init(
                code: "toml.unsupported_field",
                severity: .note,
                message: "unsupported or host-only field: \(u)"
            ))
        }

        guard let id = root["id"]?.string, !id.isEmpty else {
            throw ExtensionError.dataLoad("missing id")
        }
        let name = root["name"]?.string ?? id
        let version = root["version"]?.string ?? "1.0.0"
        let schemaVersion = root["schema_version"]?.int ?? 1
        if schemaVersion != 1 {
            diagnostics.append(.init(
                code: "toml.schema",
                severity: .error,
                message: "unsupported schema_version \(schemaVersion); expected 1"
            ))
            throw ExtensionError.dataLoad("unsupported schema_version")
        }
        let apiVersion = root["api_version"]?.string ?? "1.0"

        var activation: [String] = ["startup"]
        if case .table(let act) = root["activation"], case .array(let events) = act["events"] {
            activation = events.compactMap(\.string)
        }

        var runtimeKind: String?
        var runtimeEntrypoint: String?
        if case .table(let rt) = root["runtime"] {
            runtimeKind = rt["kind"]?.string
            runtimeEntrypoint = rt["entrypoint"]?.string
        }

        var capabilities: [String] = []
        if case .array(let arr) = root["capabilities"] {
            capabilities = arr.compactMap(\.string)
        }
        // [[capabilities]] name/kind = "..."
        if let caps = arrayTables["capabilities"] {
            for table in caps {
                if let n = table["name"]?.string {
                    capabilities.append(n)
                } else if let k = table["kind"]?.string {
                    // Zed-style process:exec etc. — record raw for unsupported reporting
                    capabilities.append(k)
                    if HostCapability(rawValue: k) == nil {
                        diagnostics.append(.init(
                            code: "toml.capability_unmapped",
                            severity: .note,
                            message: "capability kind not mapped to HostCapability: \(k)"
                        ))
                    }
                }
            }
        }

        var permissions: [String] = []
        if case .array(let arr) = root["permissions"] {
            permissions = arr.compactMap(\.string)
        } else if case .table(let t) = root["permissions"], case .array(let arr) = t["grants"] {
            permissions = arr.compactMap(\.string)
        }

        let authors: [String]
        if case .array(let arr) = root["authors"] {
            authors = arr.compactMap(\.string)
        } else {
            authors = []
        }

        // [language_servers.<id>] tables (dotted section keys)
        var languageServers: [LanguageServerContribution] = []
        for (key, value) in root {
            guard key.hasPrefix("language_servers."), case .table(let table) = value else { continue }
            let serverID = String(key.dropFirst("language_servers.".count))
            guard !serverID.isEmpty else { continue }
            let langs: [String]
            if case .array(let arr) = table["languages"] {
                langs = arr.compactMap(\.string)
            } else {
                langs = []
            }
            let args: [String]
            if case .array(let arr) = table["args"] ?? table["arguments"] {
                args = arr.compactMap(\.string)
            } else {
                args = []
            }
            // Note unknown keys
            let knownLS = Set([
                "languages", "command", "args", "arguments", "name", "display_name",
                "download_url", "download_digest", "npm_package", "npm_version", "npm_bin",
            ])
            for k in table.keys where !knownLS.contains(k) {
                diagnostics.append(.init(
                    code: "language_server.unsupported",
                    severity: .note,
                    message: "unsupported language_server field \(k) on \(serverID)"
                ))
            }
            languageServers.append(LanguageServerContribution(
                serverID: serverID,
                displayName: table["name"]?.string ?? table["display_name"]?.string ?? serverID,
                languages: langs,
                command: table["command"]?.string,
                arguments: args,
                downloadURL: table["download_url"]?.string,
                downloadDigest: table["download_digest"]?.string,
                npmPackage: table["npm_package"]?.string,
                npmVersion: table["npm_version"]?.string,
                npmBin: table["npm_bin"]?.string
            ))
        }
        languageServers.sort { $0.serverID < $1.serverID }

        let manifest = ExtensionTOMLManifest(
            id: id,
            name: name,
            description: root["description"]?.string,
            version: version,
            schemaVersion: schemaVersion,
            apiVersion: apiVersion,
            authors: authors,
            repository: root["repository"]?.string,
            license: root["license"]?.string,
            activationEvents: activation,
            runtimeKind: runtimeKind,
            runtimeEntrypoint: runtimeEntrypoint,
            capabilities: capabilities,
            permissions: permissions,
            languageServers: languageServers,
            unsupportedFields: Array(unsupported).sorted()
        )
        return (manifest, diagnostics)
    }

    public static func parse(data: Data) throws -> (manifest: ExtensionTOMLManifest, diagnostics: [ExtensionPackageDiagnostic]) {
        guard let string = String(data: data, encoding: .utf8) else {
            throw ExtensionError.dataLoad("manifest is not UTF-8")
        }
        return try parse(string: string)
    }

    // MARK: - Value parse

    private enum TOMLValue: Sendable {
        case string(String)
        case int(Int)
        case bool(Bool)
        case array([TOMLValue])
        case table([String: TOMLValue])

        var string: String? {
            if case .string(let s) = self { return s }
            if case .int(let i) = self { return String(i) }
            return nil
        }

        var int: Int? {
            if case .int(let i) = self { return i }
            if case .string(let s) = self { return Int(s) }
            return nil
        }
    }

    private static func parseValue(_ raw: String) -> TOMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            return .string(String(s.dropFirst().dropLast()))
        }
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            return .string(String(s.dropFirst().dropLast()))
        }
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = String(s.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty {
                return .array([])
            }
            let parts = splitArray(inner)
            return .array(parts.map { parseValue($0) })
        }
        if let i = Int(s) { return .int(i) }
        return .string(s)
    }

    private static func splitArray(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil; inString = false }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                inString = true
                current.append(ch)
                continue
            }
            if ch == "," && !inString {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }
}
