import Foundation
import CodeEditorCommands
import CodeEditorLanguageSupport

/// Declarative extension payload (no code execution).
public struct DataExtensionBundle: Sendable {
    public var manifest: ExtensionManifest
    public var themes: [ThemeContribution]
    public var snippets: [SnippetContribution]
    public var keybindingOverrides: [KeybindingOverrideDTO]
    public var languageDefinitions: [LanguageDefinitionDTO]

    public init(
        manifest: ExtensionManifest,
        themes: [ThemeContribution] = [],
        snippets: [SnippetContribution] = [],
        keybindingOverrides: [KeybindingOverrideDTO] = [],
        languageDefinitions: [LanguageDefinitionDTO] = []
    ) {
        self.manifest = manifest
        self.themes = themes
        self.snippets = snippets
        self.keybindingOverrides = keybindingOverrides
        self.languageDefinitions = languageDefinitions
    }
}

/// Codable keybinding override for data bundles.
public struct KeybindingOverrideDTO: Sendable, Hashable, Codable {
    public var commandID: String
    public var key: String
    public var modifiers: [String]
    public var priority: Int

    public init(
        commandID: String,
        key: String,
        modifiers: [String] = [],
        priority: Int = 0
    ) {
        self.commandID = commandID
        self.key = key
        self.modifiers = modifiers
        self.priority = priority
    }

    public func makeOverride() -> KeybindingOverride {
        var mods: KeyModifier = []
        for m in modifiers {
            switch m.lowercased() {
            case "command", "cmd", "meta": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "option", "alt": mods.insert(.option)
            case "control", "ctrl": mods.insert(.control)
            default: break
            }
        }
        return KeybindingOverride(
            commandID: CommandID(rawValue: commandID),
            keybinding: Keybinding(key: key, modifiers: mods),
            source: .extensionModule,
            priority: priority
        )
    }
}

private struct DataExtensionFile: Codable {
    var id: String
    var displayName: String
    var version: String?
    var requiredAPIVersion: String?
    var activationEvents: [String]?
    var requiredHostCapabilities: [String]?
    var requestedPermissions: [String]?
    var themes: [ThemeJSON]?
    var snippets: [SnippetJSON]?
    var keybindings: [KeybindingOverrideDTO]?
    var languages: [LanguageDefinitionDTO]?
}

private struct ThemeJSON: Codable {
    var id: String
    var displayName: String
    var tokens: [String: String]?
}

private struct SnippetJSON: Codable {
    var id: String
    var prefix: String
    var body: String
    var languageID: String?
    var description: String?
}

/// Loads data-only extension bundles from JSON.
public enum DataExtensionLoader {
    public static func load(json: Data) throws -> DataExtensionBundle {
        let decoder = JSONDecoder()
        let file: DataExtensionFile
        do {
            file = try decoder.decode(DataExtensionFile.self, from: json)
        } catch {
            throw ExtensionError.dataLoad(String(describing: error))
        }

        let version = SemanticVersion.parse(file.version ?? "1.0.0") ?? SemanticVersion(major: 1)
        let apiMin = SemanticVersion.parse(file.requiredAPIVersion ?? "1.0.0") ?? .phase9API

        let events: [ExtensionActivationEvent] = (file.activationEvents ?? ["startup"]).compactMap {
            parseActivationEvent($0)
        }

        let caps = Set((file.requiredHostCapabilities ?? []).compactMap { HostCapability(rawValue: $0) })
        let perms = Set((file.requestedPermissions ?? []).compactMap { ExtensionPermission(rawValue: $0) })

        let manifest = ExtensionManifest(
            id: ExtensionID(rawValue: file.id),
            displayName: file.displayName,
            version: version,
            requiredAPIVersion: .from(apiMin),
            activationEvents: events.isEmpty ? [.startup] : events,
            requiredHostCapabilities: caps,
            requestedPermissions: perms
        )

        let themes = (file.themes ?? []).map {
            ThemeContribution(id: $0.id, displayName: $0.displayName, tokens: $0.tokens ?? [:])
        }
        let snippets = (file.snippets ?? []).map {
            SnippetContribution(
                id: $0.id,
                prefix: $0.prefix,
                body: $0.body,
                languageID: $0.languageID,
                description: $0.description
            )
        }

        return DataExtensionBundle(
            manifest: manifest,
            themes: themes,
            snippets: snippets,
            keybindingOverrides: file.keybindings ?? [],
            languageDefinitions: file.languages ?? []
        )
    }

    public static func load(from directory: URL) throws -> DataExtensionBundle {
        let packageURL = directory.appendingPathComponent("extension.json")
        let data = try Data(contentsOf: packageURL)
        return try load(json: data)
    }

    /// Wraps a data bundle as an activatable in-process extension.
    public static func makeExtension(from bundle: DataExtensionBundle) -> any CodeEditorExtension {
        DataOnlyExtension(bundle: bundle)
    }

    private static func parseActivationEvent(_ raw: String) -> ExtensionActivationEvent? {
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

struct DataOnlyExtension: CodeEditorExtension {
    let bundle: DataExtensionBundle
    var manifest: ExtensionManifest { bundle.manifest }

    func activate(in context: ExtensionContext) async throws {
        for theme in bundle.themes {
            if let reg = context.themes {
                context.track(reg.register(theme))
            }
        }
        for snippet in bundle.snippets {
            if let reg = context.snippets {
                context.track(reg.register(snippet))
            }
        }
        for lang in bundle.languageDefinitions {
            if let reg = context.languages {
                context.track(reg.register(lang))
            }
        }
        if !bundle.keybindingOverrides.isEmpty, let kb = context.keybindings {
            let overrides = bundle.keybindingOverrides.map { $0.makeOverride() }
            let token = await MainActor.run {
                kb.applyOverrides(overrides)
            }
            context.track(token)
        }
        context.info("Data extension activated (\(bundle.themes.count) themes, \(bundle.snippets.count) snippets)")
    }
}
