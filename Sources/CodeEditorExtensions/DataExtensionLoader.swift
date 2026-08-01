import Foundation
import CodeEditorCommands
import CodeEditorLanguageSupport
import CodeEditorExtensionAPI

/// Declarative extension payload (no code execution).
public struct DataExtensionBundle: Sendable {
    public var manifest: ExtensionManifest
    public var themes: [ThemeContribution]
    public var snippets: [SnippetContribution]
    public var keybindingOverrides: [KeybindingOverrideDTO]
    public var languageDefinitions: [LanguageDefinitionDTO]
    public var iconThemes: [IconThemeContribution]
    public var plan: ValidatedContributionPlan?

    public init(
        manifest: ExtensionManifest,
        themes: [ThemeContribution] = [],
        snippets: [SnippetContribution] = [],
        keybindingOverrides: [KeybindingOverrideDTO] = [],
        languageDefinitions: [LanguageDefinitionDTO] = [],
        iconThemes: [IconThemeContribution] = [],
        plan: ValidatedContributionPlan? = nil
    ) {
        self.manifest = manifest
        self.themes = themes
        self.snippets = snippets
        self.keybindingOverrides = keybindingOverrides
        self.languageDefinitions = languageDefinitions
        self.iconThemes = iconThemes
        self.plan = plan
    }

    public init(plan: ValidatedContributionPlan) {
        self.manifest = plan.manifest
        self.themes = plan.themes
        self.snippets = plan.snippets
        self.keybindingOverrides = plan.keybindings
        self.languageDefinitions = plan.languages
        self.iconThemes = plan.iconThemes
        self.plan = plan
    }
}

public extension KeybindingOverrideDTO {
    func makeOverride() -> KeybindingOverride? {
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
        guard let id = CommandID(rawValue: commandID) else {
            return nil
        }
        return KeybindingOverride(
            commandID: id,
            keybinding: Keybinding(key: key, modifiers: mods),
            source: .extensionModule,
            priority: priority
        )
    }
}

/// Loads data-only extension bundles. Prefer ``ExtensionPackageLoader``; this remains a legacy adapter.
public enum DataExtensionLoader {
    /// Load from package directory (TOML preferred, JSON legacy).
    public static func load(from directory: URL, allowLegacyJSON: Bool = true) throws -> DataExtensionBundle {
        let plan = try ExtensionPackageLoader.load(
            directory: directory,
            options: .init(allowLegacyJSON: allowLegacyJSON, computeDigest: true)
        )
        return DataExtensionBundle(plan: plan)
    }

    public static func load(json: Data) throws -> DataExtensionBundle {
        // Write temp file for unified loader path
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try json.write(to: tmp.appendingPathComponent("extension.json"))
        return try load(from: tmp, allowLegacyJSON: true)
    }

    /// Wraps a data bundle as an activatable in-process extension.
    public static func makeExtension(from bundle: DataExtensionBundle) -> any CodeEditorExtension {
        DataOnlyExtension(bundle: bundle)
    }

    public static func makeExtension(from plan: ValidatedContributionPlan) -> any CodeEditorExtension {
        DataOnlyExtension(bundle: DataExtensionBundle(plan: plan))
    }
}

struct DataOnlyExtension: CodeEditorExtension {
    let bundle: DataExtensionBundle
    var manifest: ExtensionManifest { bundle.manifest }

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let ctx = context as? ExtensionContext else {
            // Minimal author context: only log
            context.info("Data extension activated without host registrars")
            return
        }
        for theme in bundle.themes {
            if let reg = ctx.themes {
                ctx.track(reg.register(theme))
            }
        }
        for snippet in bundle.snippets {
            if let reg = ctx.snippets {
                ctx.track(reg.register(snippet))
            }
        }
        for lang in bundle.languageDefinitions {
            if let reg = ctx.languages {
                ctx.track(reg.register(lang))
            }
        }
        for icon in bundle.iconThemes {
            if let reg = ctx.iconThemes {
                ctx.track(reg.register(icon))
            }
        }
        if !bundle.keybindingOverrides.isEmpty, let kb = ctx.keybindings {
            let overrides = bundle.keybindingOverrides.compactMap { $0.makeOverride() }
            let token = await MainActor.run {
                kb.applyOverrides(overrides)
            }
            ctx.track(token)
        }
        ctx.info(
            "Data extension activated (\(bundle.themes.count) themes, \(bundle.snippets.count) snippets, \(bundle.iconThemes.count) icon themes)"
        )
    }
}
