import CodeEditorCommands
import CodeEditorExtensionAPI
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation

/// Host-injected factories and shared stores for the extension runtime.
public struct ExtensionHostServices: Sendable {
    public var commandRegistry: CommandRegistry?
    public var keybindingRegistry: KeybindingRegistry?
    public var languageRegistry: LanguageRegistry?
    public var languageServiceRegistry: LanguageServiceRegistry?
    public var panelStore: PanelContributionStore
    public var themeStore: ThemeContributionStore
    public var snippetStore: SnippetContributionStore
    public var iconThemeStore: IconThemeContributionStore
    public var storageRoot: URL?

    public init(
        commandRegistry: CommandRegistry? = nil,
        keybindingRegistry: KeybindingRegistry? = nil,
        languageRegistry: LanguageRegistry? = .shared,
        languageServiceRegistry: LanguageServiceRegistry? = nil,
        panelStore: PanelContributionStore = PanelContributionStore(),
        themeStore: ThemeContributionStore = ThemeContributionStore(),
        snippetStore: SnippetContributionStore = SnippetContributionStore(),
        iconThemeStore: IconThemeContributionStore = IconThemeContributionStore(),
        storageRoot: URL? = nil
    ) {
        self.commandRegistry = commandRegistry
        self.keybindingRegistry = keybindingRegistry
        self.languageRegistry = languageRegistry
        self.languageServiceRegistry = languageServiceRegistry
        self.panelStore = panelStore
        self.themeStore = themeStore
        self.snippetStore = snippetStore
        self.iconThemeStore = iconThemeStore
        self.storageRoot = storageRoot
    }

    /// Convenience full host for tests and rich apps.
    @MainActor
    public static func makeFull(
        commands: CommandRegistry = CommandRegistry(),
        keybindings: KeybindingRegistry = KeybindingRegistry(),
        languageServices: LanguageServiceRegistry = LanguageServiceRegistry(),
        storageRoot: URL? = nil
    ) -> ExtensionHostServices {
        ExtensionHostServices(
            commandRegistry: commands,
            keybindingRegistry: keybindings,
            languageRegistry: .shared,
            languageServiceRegistry: languageServices,
            storageRoot: storageRoot
        )
    }
}
