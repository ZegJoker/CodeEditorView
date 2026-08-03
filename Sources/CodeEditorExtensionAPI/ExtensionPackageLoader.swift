import Foundation

/// Loads packages into ``ValidatedContributionPlan`` (TOML preferred, JSON legacy).
public enum ExtensionPackageLoader {
    public struct LoadOptions: Sendable {
        public var allowLegacyJSON: Bool
        public var computeDigest: Bool
        public var expectedDigest: String?
        /// Reject packages whose resolved paths escape the package root (symlink attacks).
        public var enforcePathContainment: Bool

        public init(
            allowLegacyJSON: Bool = true,
            computeDigest: Bool = true,
            expectedDigest: String? = nil,
            enforcePathContainment: Bool = true
        ) {
            self.allowLegacyJSON = allowLegacyJSON
            self.computeDigest = computeDigest
            self.expectedDigest = expectedDigest
            self.enforcePathContainment = enforcePathContainment
        }

        public static let `default` = LoadOptions()
    }

    public static func load(directory: URL, options: LoadOptions = .default) throws -> ValidatedContributionPlan {
        let root = directory.standardizedFileURL
        try validatePackageRoot(root, enforceContainment: options.enforcePathContainment)

        let tomlURL = root.appendingPathComponent("extension.toml")
        let jsonURL = root.appendingPathComponent("extension.json")
        let fm = FileManager.default
        let hasTOML = fm.fileExists(atPath: tomlURL.path)
        let hasJSON = fm.fileExists(atPath: jsonURL.path)

        var diagnostics: [ExtensionPackageDiagnostic] = []

        if hasTOML && hasJSON {
            diagnostics.append(
                .init(
                    code: "package.dual_manifest",
                    severity: .warning,
                    message: "both extension.toml and extension.json present; TOML wins",
                    path: "extension.toml"
                ))
        }

        let plan: ValidatedContributionPlan
        if hasTOML {
            plan = try loadTOML(directory: root, diagnostics: &diagnostics)
        } else if hasJSON {
            if !options.allowLegacyJSON {
                throw ExtensionError.dataLoad("extension.json not allowed (legacy disabled)")
            }
            diagnostics.append(
                .init(
                    code: "package.legacy_json",
                    severity: .warning,
                    message: "loading legacy extension.json; migrate to extension.toml",
                    path: "extension.json"
                ))
            plan = try loadLegacyJSON(directory: root, diagnostics: &diagnostics)
        } else {
            throw ExtensionError.dataLoad("no extension.toml or extension.json in \(root.path)")
        }

        var result = plan
        result.diagnostics.append(contentsOf: diagnostics)
        result.diagnostics = dedupeDiagnostics(result.diagnostics)

        if options.computeDigest {
            let digest = try ExtensionPackageDigest.compute(packageRoot: root)
            result.digest = digest
            if let expected = options.expectedDigest, expected != digest {
                throw ExtensionError.dataLoad("digest mismatch: expected \(expected), got \(digest)")
            }
        }
        return result
    }

    // MARK: - Root safety

    private static func validatePackageRoot(_ root: URL, enforceContainment: Bool) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ExtensionError.dataLoad("package root is not a directory: \(root.path)")
        }
        guard enforceContainment else { return }
        // Resolve symlinks on root; individual files validated relative to this.
        let resolved = root.resolvingSymlinksInPath()
        if resolved.path != root.path && !resolved.path.hasPrefix(root.path) {
            // Allow resolved path when root itself is a symlink into a real folder.
        }
    }

    /// Ensures `url` stays under `root` after symlink resolution.
    public static func isPathContained(url: URL, within root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == resolvedRoot { return true }
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolved.hasPrefix(prefix)
    }

    // MARK: - TOML

    private static func loadTOML(
        directory: URL,
        diagnostics: inout [ExtensionPackageDiagnostic]
    ) throws -> ValidatedContributionPlan {
        let tomlURL = directory.appendingPathComponent("extension.toml")
        let data = try Data(contentsOf: tomlURL)
        let (toml, diags) = try ExtensionTOMLParser.parse(data: data)
        diagnostics.append(contentsOf: diags)
        if diagnostics.contains(where: { $0.severity == .error }) {
            // still attempt convert if no throw
        }
        let manifest = try toml.toExtensionManifest()

        var themes: [ThemeContribution] = []
        var snippets: [SnippetContribution] = []
        var icons: [IconThemeContribution] = []
        var languages: [LanguageDefinitionDTO] = []
        var grammars: [GrammarContribution] = []
        var queries: [QueryContribution] = []
        var assets: [AssetContribution] = []

        let themesDir = directory.appendingPathComponent("themes")
        if let files = try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.path < $1.path })
            where file.pathExtension == "json" || file.pathExtension == "toml" {
                guard isPathContained(url: file, within: directory) else {
                    diagnostics.append(
                        .init(
                            code: "package.path_escape",
                            severity: .error,
                            message: "theme path escapes package: \(file.lastPathComponent)",
                            path: file.lastPathComponent
                        ))
                    continue
                }
                do {
                    themes.append(try loadThemeFile(file, extensionID: manifest.id))
                } catch {
                    diagnostics.append(
                        .init(
                            code: "theme.load_failed",
                            severity: .error,
                            message: "failed to load theme \(file.lastPathComponent): \(error)",
                            path: relativePath(file, root: directory)
                        ))
                }
            }
        }

        let snippetsDir = directory.appendingPathComponent("snippets")
        if let files = try? FileManager.default.contentsOfDirectory(at: snippetsDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
                guard isPathContained(url: file, within: directory) else { continue }
                do {
                    snippets.append(contentsOf: try loadSnippetsFile(file, extensionID: manifest.id))
                } catch {
                    diagnostics.append(
                        .init(
                            code: "snippet.load_failed",
                            severity: .error,
                            message: "failed to load snippets \(file.lastPathComponent): \(error)",
                            path: relativePath(file, root: directory)
                        ))
                }
            }
        }

        let iconsDir = directory.appendingPathComponent("icon_themes")
        if let files = try? FileManager.default.contentsOfDirectory(at: iconsDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.path < $1.path })
            where file.pathExtension == "json" || file.pathExtension == "toml" {
                guard isPathContained(url: file, within: directory) else { continue }
                do {
                    icons.append(try loadIconThemeFile(file, extensionID: manifest.id))
                } catch {
                    diagnostics.append(
                        .init(
                            code: "icon_theme.load_failed",
                            severity: .error,
                            message: "failed to load icon theme \(file.lastPathComponent): \(error)",
                            path: relativePath(file, root: directory)
                        ))
                }
            }
        }

        let languagesDir = directory.appendingPathComponent("languages")
        if let langDirs = try? FileManager.default.contentsOfDirectory(
            at: languagesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for langDir in langDirs.sorted(by: { $0.path < $1.path }) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: langDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                guard isPathContained(url: langDir, within: directory) else { continue }
                let folder = langDir.lastPathComponent
                let config = langDir.appendingPathComponent("config.toml")
                if FileManager.default.fileExists(atPath: config.path) {
                    do {
                        let lang = try loadLanguageConfig(config, folderName: folder)
                        languages.append(lang)
                        // Query files
                        let queryKinds = [
                            "highlights", "brackets", "indents", "injections",
                            "outline", "textobjects", "overrides", "locals",
                        ]
                        for kind in queryKinds {
                            let q = langDir.appendingPathComponent("\(kind).scm")
                            if FileManager.default.fileExists(atPath: q.path) {
                                queries.append(
                                    QueryContribution(
                                        languageID: lang.id,
                                        kind: kind,
                                        relativePath: relativePath(q, root: directory),
                                        extensionID: manifest.id
                                    ))
                            }
                        }
                    } catch {
                        diagnostics.append(
                            .init(
                                code: "language.load_failed",
                                severity: .error,
                                message: "failed to load language \(folder): \(error)",
                                path: relativePath(config, root: directory)
                            ))
                    }
                }
            }
        }

        let grammarsDir = directory.appendingPathComponent("grammars")
        if let grammarDirs = try? FileManager.default.contentsOfDirectory(
            at: grammarsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for gDir in grammarDirs.sorted(by: { $0.path < $1.path }) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: gDir.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let name = gDir.lastPathComponent
                let grammarToml = gDir.appendingPathComponent("grammar.toml")
                var repository: String?
                var commit: String?
                var grammarPath: String?
                if FileManager.default.fileExists(atPath: grammarToml.path),
                    let text = try? String(contentsOf: grammarToml, encoding: .utf8)
                {
                    for line in text.split(separator: "\n") {
                        let l = line.trimmingCharacters(in: .whitespaces)
                        if l.hasPrefix("#") || l.isEmpty { continue }
                        if l.hasPrefix("repository") {
                            repository = quotedValue(String(l))
                        } else if l.hasPrefix("commit") || l.hasPrefix("rev") {
                            commit = quotedValue(String(l))
                        } else if l.hasPrefix("path") {
                            if let rel = quotedValue(String(l)) {
                                grammarPath = "grammars/\(name)/\(rel)"
                            }
                        }
                    }
                }
                // Also accept grammar source files without grammar.toml
                if grammarPath == nil {
                    let candidates = ["src/parser.c", "parser.c", "grammar.js"]
                    for c in candidates {
                        let p = gDir.appendingPathComponent(c)
                        if FileManager.default.fileExists(atPath: p.path) {
                            grammarPath = relativePath(p, root: directory)
                            break
                        }
                    }
                }
                grammars.append(
                    GrammarContribution(
                        id: name,
                        languageID: name,
                        grammarPath: grammarPath,
                        repository: repository,
                        commit: commit,
                        extensionID: manifest.id
                    ))
            }
        }

        let assetsDir = directory.appendingPathComponent("assets")
        if let enumerator = FileManager.default.enumerator(
            at: assetsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard isPathContained(url: url, within: directory) else {
                    diagnostics.append(
                        .init(
                            code: "package.path_escape",
                            severity: .error,
                            message: "asset path escapes package",
                            path: url.path
                        ))
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                assets.append(
                    AssetContribution(
                        relativePath: relativePath(url, root: directory),
                        absoluteURL: url
                    ))
            }
        }

        var languageServers = toml.languageServers.map { contrib -> LanguageServerContribution in
            var c = contrib
            c.extensionID = manifest.id
            return c
        }
        var debugAdapters = toml.debugAdapters.map { contrib -> DebugAdapterContribution in
            var c = contrib
            c.extensionID = manifest.id
            return c
        }
        var mcpServers = toml.mcpServers.map { contrib -> MCPServerContribution in
            var c = contrib
            c.extensionID = manifest.id
            return c
        }
        var slashCommands = toml.slashCommands.map { contrib -> SlashCommandContribution in
            var c = contrib
            c.extensionID = manifest.id
            return c
        }
        var documentationPackages = toml.documentationPackages.map { contrib -> DocumentationPackageContribution in
            var c = contrib
            c.extensionID = manifest.id
            return c
        }

        let hasData =
            !themes.isEmpty || !snippets.isEmpty || !icons.isEmpty
            || !languages.isEmpty || !grammars.isEmpty || !queries.isEmpty
            || !languageServers.isEmpty || !debugAdapters.isEmpty || !mcpServers.isEmpty
            || !slashCommands.isEmpty || !documentationPackages.isEmpty
        let parity: String
        if !debugAdapters.isEmpty || !mcpServers.isEmpty {
            parity = "codeeditor-dap-mcp-s2"
        } else if !languageServers.isEmpty {
            parity = "codeeditor-ls-s2"
        } else if hasData {
            parity = "codeeditor-data-s1"
        } else {
            parity = "codeeditor-data-s0"
        }

        return ValidatedContributionPlan(
            packageID: manifest.id,
            displayName: manifest.displayName,
            version: manifest.version,
            manifest: manifest,
            packageRoot: directory,
            sourceFormat: .toml,
            themes: themes,
            snippets: snippets,
            iconThemes: icons,
            languages: languages,
            grammars: grammars,
            queries: queries,
            languageServers: languageServers,
            debugAdapters: debugAdapters,
            mcpServers: mcpServers,
            slashCommands: slashCommands,
            documentationPackages: documentationPackages,
            assets: assets.sorted { $0.relativePath < $1.relativePath },
            diagnostics: diagnostics,
            unsupportedFields: toml.unsupportedFields,
            parityProfile: parity,
            manifestRuntimeKind: toml.runtimeKind,
            manifestRuntimeEntrypoint: toml.runtimeEntrypoint
        )
    }

    // MARK: - Legacy JSON bridge

    private static func loadLegacyJSON(
        directory: URL,
        diagnostics: inout [ExtensionPackageDiagnostic]
    ) throws -> ValidatedContributionPlan {
        let jsonURL = directory.appendingPathComponent("extension.json")
        let data = try Data(contentsOf: jsonURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let obj, let id = obj["id"] as? String, let displayName = obj["displayName"] as? String else {
            throw ExtensionError.dataLoad("invalid extension.json: missing id or displayName")
        }
        let version = SemanticVersion.parse(obj["version"] as? String ?? "1.0.0") ?? SemanticVersion(major: 1)
        let apiMin = SemanticVersion.parse(obj["requiredAPIVersion"] as? String ?? "1.0.0") ?? .phase9API
        let eventsRaw = obj["activationEvents"] as? [String] ?? ["startup"]
        let events = eventsRaw.compactMap(ExtensionTOMLManifest.parseActivationEvent)
        let caps = Set((obj["requiredHostCapabilities"] as? [String] ?? []).compactMap { HostCapability(rawValue: $0) })
        let perms = Set(
            (obj["requestedPermissions"] as? [String] ?? []).compactMap { ExtensionPermission(rawValue: $0) })
        let extensionID: ExtensionID
        do {
            extensionID = try ExtensionID(validating: id)
        } catch {
            throw ExtensionError.dataLoad("invalid extension id: \(id)")
        }
        let manifest = ExtensionManifest(
            id: extensionID,
            displayName: displayName,
            version: version,
            requiredAPIVersion: .from(apiMin),
            activationEvents: events.isEmpty ? [.startup] : events,
            requiredHostCapabilities: caps,
            requestedPermissions: perms
        )

        var themes: [ThemeContribution] = []
        if let arr = obj["themes"] as? [[String: Any]] {
            for t in arr {
                guard let tid = t["id"] as? String, let name = t["displayName"] as? String else { continue }
                themes.append(
                    ThemeContribution(
                        id: tid,
                        displayName: name,
                        tokens: t["tokens"] as? [String: String] ?? [:],
                        extensionID: manifest.id
                    ))
            }
        }

        var snippets: [SnippetContribution] = []
        if let arr = obj["snippets"] as? [[String: Any]] {
            for s in arr {
                guard let sid = s["id"] as? String,
                    let prefix = s["prefix"] as? String,
                    let body = s["body"] as? String
                else { continue }
                snippets.append(
                    SnippetContribution(
                        id: sid,
                        prefix: prefix,
                        body: body,
                        languageID: s["languageID"] as? String,
                        description: s["description"] as? String,
                        extensionID: manifest.id
                    ))
            }
        }

        var languages: [LanguageDefinitionDTO] = []
        if let arr = obj["languages"] as? [[String: Any]] {
            for l in arr {
                guard let lid = l["id"] as? String else { continue }
                languages.append(
                    LanguageDefinitionDTO(
                        id: lid,
                        displayName: l["displayName"] as? String ?? lid,
                        tsName: l["tsName"] as? String ?? lid,
                        fileExtensions: l["fileExtensions"] as? [String] ?? [],
                        aliases: l["aliases"] as? [String] ?? [],
                        lineComment: l["lineComment"] as? String ?? "",
                        blockCommentStart: l["blockCommentStart"] as? String ?? "",
                        blockCommentEnd: l["blockCommentEnd"] as? String ?? ""
                    ))
            }
        }

        var icons: [IconThemeContribution] = []
        if let arr = obj["iconThemes"] as? [[String: Any]] {
            for t in arr {
                guard let tid = t["id"] as? String else { continue }
                icons.append(
                    IconThemeContribution(
                        id: tid,
                        displayName: t["displayName"] as? String ?? tid,
                        fileIcons: t["fileIcons"] as? [String: String] ?? [:],
                        folderIcons: t["folderIcons"] as? [String: String] ?? [:],
                        extensionID: manifest.id
                    ))
            }
        }

        var keybindings: [KeybindingOverrideDTO] = []
        if let arr = obj["keybindings"] as? [[String: Any]] {
            for k in arr {
                guard let cmd = k["commandID"] as? String, let key = k["key"] as? String else { continue }
                keybindings.append(
                    KeybindingOverrideDTO(
                        commandID: cmd,
                        key: key,
                        modifiers: k["modifiers"] as? [String] ?? [],
                        priority: k["priority"] as? Int ?? 0
                    ))
            }
        }

        // Also pick up conventional folders next to legacy JSON if present
        if themes.isEmpty {
            let themesDir = directory.appendingPathComponent("themes")
            if let files = try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil)
            {
                for file in files where file.pathExtension == "json" {
                    if let theme = try? loadThemeFile(file, extensionID: manifest.id) {
                        themes.append(theme)
                    }
                }
            }
        }

        return ValidatedContributionPlan(
            packageID: manifest.id,
            displayName: manifest.displayName,
            version: version,
            manifest: manifest,
            packageRoot: directory,
            sourceFormat: .legacyJSON,
            themes: themes,
            snippets: snippets,
            iconThemes: icons,
            languages: languages,
            keybindings: keybindings,
            diagnostics: diagnostics,
            parityProfile: "codeeditor-data-s1-legacy-json"
        )
    }

    // MARK: - File helpers

    private static func loadThemeFile(_ url: URL, extensionID: ExtensionID) throws -> ThemeContribution {
        if url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let id = obj?["id"] as? String ?? url.deletingPathExtension().lastPathComponent
            let name = obj?["displayName"] as? String ?? obj?["name"] as? String ?? id
            let tokens = obj?["tokens"] as? [String: String] ?? [:]
            return ThemeContribution(id: id, displayName: name, tokens: tokens, extensionID: extensionID)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var id = url.deletingPathExtension().lastPathComponent
        var name = id
        var tokens: [String: String] = [:]
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#"), !line[..<hash].contains("\"") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if section == "tokens" || section.hasSuffix(".tokens") {
                tokens[key] = value
            } else if section.isEmpty {
                switch key {
                case "id": id = value
                case "name", "display_name", "displayName": name = value
                default: break
                }
            }
        }
        return ThemeContribution(id: id, displayName: name, tokens: tokens, extensionID: extensionID)
    }

    private static func loadSnippetsFile(_ url: URL, extensionID: ExtensionID) throws -> [SnippetContribution] {
        let data = try Data(contentsOf: url)
        // Support array form and VSCode-like dictionary form
        let json = try JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]] {
            return arr.compactMap { s in
                guard let id = s["id"] as? String,
                    let prefix = s["prefix"] as? String,
                    let body = s["body"] as? String
                else { return nil }
                return SnippetContribution(
                    id: id,
                    prefix: prefix,
                    body: body,
                    languageID: s["languageID"] as? String,
                    description: s["description"] as? String,
                    extensionID: extensionID
                )
            }
        }
        if let dict = json as? [String: [String: Any]] {
            return dict.compactMap { key, s in
                let prefix: String
                if let p = s["prefix"] as? String {
                    prefix = p
                } else if let arr = s["prefix"] as? [String], let first = arr.first {
                    prefix = first
                } else {
                    return nil
                }
                let body: String
                if let b = s["body"] as? String {
                    body = b
                } else if let arr = s["body"] as? [String] {
                    body = arr.joined(separator: "\n")
                } else {
                    return nil
                }
                return SnippetContribution(
                    id: key,
                    prefix: prefix,
                    body: body,
                    languageID: s["languageID"] as? String ?? s["scope"] as? String,
                    description: s["description"] as? String,
                    extensionID: extensionID
                )
            }
        }
        return []
    }

    private static func loadIconThemeFile(_ url: URL, extensionID: ExtensionID) throws -> IconThemeContribution {
        if url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let id = obj?["id"] as? String ?? url.deletingPathExtension().lastPathComponent
            return IconThemeContribution(
                id: id,
                displayName: obj?["displayName"] as? String ?? obj?["name"] as? String ?? id,
                fileIcons: obj?["fileIcons"] as? [String: String] ?? [:],
                folderIcons: obj?["folderIcons"] as? [String: String] ?? [:],
                extensionID: extensionID
            )
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var id = url.deletingPathExtension().lastPathComponent
        var name = id
        var fileIcons: [String: String] = [:]
        var folderIcons: [String: String] = [:]
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#"), !line[..<hash].contains("\"") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if section == "file_icons" || section == "fileIcons" {
                fileIcons[key] = value
            } else if section == "folder_icons" || section == "folderIcons" {
                folderIcons[key] = value
            } else if section.isEmpty {
                switch key {
                case "id": id = value
                case "name", "display_name", "displayName": name = value
                default: break
                }
            }
        }
        return IconThemeContribution(
            id: id,
            displayName: name,
            fileIcons: fileIcons,
            folderIcons: folderIcons,
            extensionID: extensionID
        )
    }

    private static func loadLanguageConfig(_ url: URL, folderName: String) throws -> LanguageDefinitionDTO {
        let text = try String(contentsOf: url, encoding: .utf8)
        var name = folderName
        var extensions: [String] = []
        var aliases: [String] = []
        var lineComment = ""
        var blockStart = ""
        var blockEnd = ""
        var tsName = folderName
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") || l.isEmpty { continue }
            if l.hasPrefix("name") || l.hasPrefix("display_name") {
                if let v = quotedValue(String(l)) { name = v }
            } else if l.hasPrefix("grammar") || l.hasPrefix("ts_name") || l.hasPrefix("tree_sitter") {
                if let v = quotedValue(String(l)) { tsName = v }
            } else if l.hasPrefix("path_suffixes") || l.hasPrefix("extensions") {
                extensions = arrayValues(String(l))
            } else if l.hasPrefix("aliases") {
                aliases = arrayValues(String(l))
            } else if l.hasPrefix("line_comments") || l.hasPrefix("line_comment") {
                if let arr = optionalArray(String(l)) {
                    lineComment = arr.first ?? ""
                } else if let v = quotedValue(String(l)) {
                    lineComment = v
                }
            } else if l.hasPrefix("block_comment") {
                let arr = arrayValues(String(l))
                if arr.count >= 2 {
                    blockStart = arr[0]
                    blockEnd = arr[1]
                }
            }
        }
        let highlights = url.deletingLastPathComponent().appendingPathComponent("highlights.scm")
        return LanguageDefinitionDTO(
            id: folderName,
            displayName: name,
            tsName: tsName,
            fileExtensions: extensions,
            aliases: aliases,
            lineComment: lineComment,
            blockCommentStart: blockStart,
            blockCommentEnd: blockEnd,
            configPath: "languages/\(folderName)/config.toml",
            highlightsQuery: FileManager.default.fileExists(atPath: highlights.path)
                ? "languages/\(folderName)/highlights.scm" : nil
        )
    }

    // MARK: - String helpers

    private static func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    private static func unquote(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func quotedValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    private static func arrayValues(_ line: String) -> [String] {
        guard let start = line.firstIndex(of: "["), let end = line.firstIndex(of: "]") else {
            if let v = quotedValue(line) { return [v] }
            return []
        }
        let inner = line[line.index(after: start)..<end]
        return inner.split(separator: ",").map {
            unquote($0.trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    private static func optionalArray(_ line: String) -> [String]? {
        guard line.contains("[") else { return nil }
        return arrayValues(line)
    }

    private static func dedupeDiagnostics(_ list: [ExtensionPackageDiagnostic]) -> [ExtensionPackageDiagnostic] {
        var seen = Set<String>()
        var out: [ExtensionPackageDiagnostic] = []
        for d in list {
            let key = "\(d.code)|\(d.message)|\(d.path ?? "")"
            if seen.insert(key).inserted {
                out.append(d)
            }
        }
        return out
    }
}
