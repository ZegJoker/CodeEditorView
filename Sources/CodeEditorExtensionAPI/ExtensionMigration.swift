import Foundation

/// JSON → TOML migration helpers (used by CLI and tests).
public enum ExtensionMigration {
    public struct Result: Sendable {
        public var packageID: ExtensionID
        public var tomlPath: URL
        public var report: String
        public var plan: ValidatedContributionPlan
        public var todos: [String]
    }

    /// Migrate a package directory that contains `extension.json` into `extension.toml` + contribution folders.
    public static func migrateJSONToTOML(
        directory: URL,
        writeSwiftTemplate: Bool = false
    ) throws -> Result {
        let root = directory.standardizedFileURL
        let jsonURL = root.appendingPathComponent("extension.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw ExtensionError.dataLoad("extension.json not found in \(root.path)")
        }

        // Load JSON payload directly so an existing extension.toml cannot mask the source.
        let jsonData = try Data(contentsOf: jsonURL)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try jsonData.write(to: tmp.appendingPathComponent("extension.json"))
        let plan = try ExtensionPackageLoader.load(
            directory: tmp,
            options: .init(allowLegacyJSON: true, computeDigest: false)
        )
        guard plan.sourceFormat == .legacyJSON else {
            throw ExtensionError.dataLoad("source is not legacy JSON")
        }

        // If TOML already exists, still rewrite from JSON payload for golden migrations.
        let m = plan.manifest
        var todos: [String] = []
        var lines: [String] = [
            "id = \"\(escapeTOML(m.id.rawValue))\"",
            "name = \"\(escapeTOML(m.displayName))\"",
            "version = \"\(m.version)\"",
            "schema_version = 1",
            "api_version = \"\(m.requiredAPIVersion.min)\"",
            "",
            "[activation]",
            "events = [\(m.activationEvents.map { "\"\(escapeTOML(activationString($0)))\"" }.joined(separator: ", "))]",
            "",
        ]
        if !m.requiredHostCapabilities.isEmpty {
            lines.append(
                "capabilities = [\(m.requiredHostCapabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))]"
            )
            lines.append("")
        }
        if !m.requestedPermissions.isEmpty {
            lines.append(
                "permissions = [\(m.requestedPermissions.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))]"
            )
            lines.append("")
        }
        lines.append("[runtime]")
        lines.append("kind = \"data-only\"")
        lines.append("")

        let tomlURL = root.appendingPathComponent("extension.toml")
        try (lines.joined(separator: "\n") + "\n").write(to: tomlURL, atomically: true, encoding: .utf8)

        if !plan.themes.isEmpty {
            let themesDir = root.appendingPathComponent("themes", isDirectory: true)
            try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
            for theme in plan.themes {
                let obj: [String: Any] = [
                    "id": theme.id,
                    "displayName": theme.displayName,
                    "tokens": theme.tokens,
                ]
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: themesDir.appendingPathComponent("\(sanitizeFileName(theme.id)).json"))
            }
        }

        if !plan.snippets.isEmpty {
            let snippetsDir = root.appendingPathComponent("snippets", isDirectory: true)
            try FileManager.default.createDirectory(at: snippetsDir, withIntermediateDirectories: true)
            let arr: [[String: Any]] = plan.snippets.map { s in
                var d: [String: Any] = ["id": s.id, "prefix": s.prefix, "body": s.body]
                if let l = s.languageID { d["languageID"] = l }
                if let desc = s.description { d["description"] = desc }
                return d
            }
            let data = try JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: snippetsDir.appendingPathComponent("snippets.json"))
        }

        if !plan.iconThemes.isEmpty {
            let iconsDir = root.appendingPathComponent("icon_themes", isDirectory: true)
            try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
            for icon in plan.iconThemes {
                let obj: [String: Any] = [
                    "id": icon.id,
                    "displayName": icon.displayName,
                    "fileIcons": icon.fileIcons,
                    "folderIcons": icon.folderIcons,
                ]
                let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: iconsDir.appendingPathComponent("\(sanitizeFileName(icon.id)).json"))
            }
        }

        if !plan.languages.isEmpty {
            let languagesDir = root.appendingPathComponent("languages", isDirectory: true)
            try FileManager.default.createDirectory(at: languagesDir, withIntermediateDirectories: true)
            for lang in plan.languages {
                let dir = languagesDir.appendingPathComponent(sanitizeFileName(lang.id), isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var cfg = """
                name = "\(escapeTOML(lang.displayName))"
                grammar = "\(escapeTOML(lang.tsName.isEmpty ? lang.id : lang.tsName))"
                path_suffixes = [\(lang.fileExtensions.map { "\"\(escapeTOML($0))\"" }.joined(separator: ", "))]
                """
                if !lang.aliases.isEmpty {
                    cfg += "\naliases = [\(lang.aliases.map { "\"\(escapeTOML($0))\"" }.joined(separator: ", "))]"
                }
                if !lang.lineComment.isEmpty {
                    cfg += "\nline_comments = [\"\(escapeTOML(lang.lineComment))\"]"
                }
                if !lang.blockCommentStart.isEmpty {
                    cfg += "\nblock_comment = [\"\(escapeTOML(lang.blockCommentStart))\", \"\(escapeTOML(lang.blockCommentEnd))\"]"
                }
                cfg += "\n"
                try cfg.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            }
        }

        if !plan.keybindings.isEmpty {
            todos.append("keybindings present in JSON (\(plan.keybindings.count)); review after migration — not auto-exported to TOML tables yet")
        }
        todos.append("review unsupported procedural fields manually")
        todos.append("delete extension.json after validating extension.toml")

        if writeSwiftTemplate {
            try writePackageTemplate(into: root, packageID: m.id, displayName: m.displayName)
            todos.append("fill in Sources/ with procedural activation if needed")
        }

        // Validate generated package preferring TOML
        let validated = try ExtensionPackageLoader.load(
            directory: root,
            options: .init(allowLegacyJSON: true, computeDigest: true)
        )

        let report = """
        # Migration report

        - source: extension.json
        - target: extension.toml
        - package: \(m.id.rawValue)
        - version: \(m.version)
        - themes exported: \(plan.themes.count)
        - snippets exported: \(plan.snippets.count)
        - icon themes exported: \(plan.iconThemes.count)
        - languages exported: \(plan.languages.count)
        - keybindings noted: \(plan.keybindings.count)
        - parity: \(validated.parityProfile)
        - digest: \(validated.digest ?? "n/a")

        ## TODO
        \(todos.map { "- \($0)" }.joined(separator: "\n"))
        """

        return Result(
            packageID: m.id,
            tomlPath: tomlURL,
            report: report,
            plan: validated,
            todos: todos
        )
    }

    public static func writePackageTemplate(
        into root: URL,
        packageID: ExtensionID,
        displayName: String
    ) throws {
        let packageSwift = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(sanitizeSwiftName(packageID.rawValue))",
            platforms: [.macOS(.v15), .iOS(.v18)],
            products: [
                .library(name: "\(sanitizeSwiftName(packageID.rawValue))", targets: ["\(sanitizeSwiftName(packageID.rawValue))"]),
            ],
            dependencies: [
                // .package(url: "https://github.com/your-org/CodeEditorView.git", from: "1.0.0"),
            ],
            targets: [
                .target(
                    name: "\(sanitizeSwiftName(packageID.rawValue))",
                    dependencies: [
                        // .product(name: "CodeEditorExtensionAPI", package: "CodeEditorView"),
                    ]
                ),
            ]
        )
        """
        try packageSwift.write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let sources = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(sanitizeSwiftName(packageID.rawValue), isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source = """
        import CodeEditorExtensionAPI

        /// \(displayName) — data-only by default. Add procedural activation when needed.
        public struct \(sanitizeSwiftName(packageID.rawValue)): EditorExtension {
            public init() {}

            public var manifest: ExtensionManifest {
                // Prefer loading from extension.toml at package root in production hosts.
                ExtensionManifest(
                    id: try! ExtensionID(validating: "\(packageID.rawValue)"),
                    displayName: "\(escapeSwiftString(displayName))",
                    activationEvents: [.startup]
                )
            }

            public func activate(in context: any ExtensionAuthorContext) async throws {
                context.info("\\(manifest.displayName) activated")
            }
        }
        """
        try source.write(
            to: sources.appendingPathComponent("\(sanitizeSwiftName(packageID.rawValue)).swift"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Helpers

    public static func activationString(_ e: ExtensionActivationEvent) -> String {
        switch e {
        case .startup: return "startup"
        case .workspaceOpened: return "workspaceOpened"
        case .manual: return "manual"
        case .language(let l): return "language:\(l)"
        case .command(let c): return "command:\(c)"
        case .fileMatch(let p): return "fileMatch:\(p)"
        case .view(let v): return "view:\(v)"
        }
    }

    private static func escapeTOML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeSwiftString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func sanitizeFileName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }

    private static func sanitizeSwiftName(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.first?.isNumber == true {
            out = "_" + out
        }
        if out.isEmpty { return "Extension" }
        // Capitalize first for type name
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
