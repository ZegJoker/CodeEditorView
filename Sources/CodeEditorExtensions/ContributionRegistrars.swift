import CodeEditorCommands
import CodeEditorExtensionAPI
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation

// MARK: - Commands

/// Registers editor commands on the host ``CommandRegistry`` (MainActor).
public final class CommandContributionRegistrar: @unchecked Sendable {
    private let registry: CommandRegistry

    public init(registry: CommandRegistry) {
        self.registry = registry
    }

    @MainActor
    @discardableResult
    public func register(_ command: EditorCommand) throws -> any ExtensionDisposable {
        let token = try registry.register(command, policy: .rejectDuplicate)
        return ExtensionRegistrationToken(wrapping: token)
    }

    public func registerAsync(_ command: EditorCommand) async throws -> any ExtensionDisposable {
        try await MainActor.run {
            try register(command)
        }
    }
}

// MARK: - Keybindings

public final class KeybindingContributionRegistrar: @unchecked Sendable {
    private let registry: KeybindingRegistry

    public init(registry: KeybindingRegistry) {
        self.registry = registry
    }

    @MainActor
    @discardableResult
    public func bind(
        _ keybinding: Keybinding,
        to command: CommandID,
        priority: Int = 0
    ) -> any ExtensionDisposable {
        let token = registry.bind(
            keybinding,
            to: command,
            source: .extensionModule,
            priority: priority
        )
        return ExtensionRegistrationToken(wrapping: token)
    }

    @MainActor
    @discardableResult
    public func applyOverrides(_ overrides: [KeybindingOverride]) -> any ExtensionDisposable {
        let normalized = overrides.map {
            KeybindingOverride(
                commandID: $0.commandID,
                keybinding: $0.keybinding,
                source: .extensionModule,
                priority: $0.priority
            )
        }
        let token = registry.applyOverrides(normalized)
        return ExtensionRegistrationToken(wrapping: token)
    }
}

// MARK: - Languages

public final class LanguageContributionRegistrar: @unchecked Sendable {
    private let registry: LanguageRegistry

    public init(registry: LanguageRegistry = .shared) {
        self.registry = registry
    }

    @discardableResult
    public func register(_ definition: LanguageDefinition) -> any ExtensionDisposable {
        registry.register(definition)
        let id = definition.id
        return ExtensionRegistrationToken { [registry] in
            registry.unregisterDefinition(for: id)
        }
    }

    @discardableResult
    public func register(_ dto: LanguageDefinitionDTO) -> any ExtensionDisposable {
        register(dto.makeDefinition())
    }
}

// MARK: - Language services

public final class LanguageServiceContributionRegistrar: @unchecked Sendable {
    private let registry: LanguageServiceRegistry
    private let extensionID: ExtensionID

    public init(registry: LanguageServiceRegistry, extensionID: ExtensionID) {
        self.registry = registry
        self.extensionID = extensionID
    }

    public func register(_ provider: any CompletionProvider) async -> any ExtensionDisposable {
        let id = namespaced(provider.id)
        let wrapped = NamespacedCompletionProvider(base: provider, id: id)
        await registry.register(wrapped)
        return ExtensionRegistrationToken { [registry] in
            Task { await registry.unregister(id: id) }
        }
    }

    public func register(_ provider: any HoverProvider) async -> any ExtensionDisposable {
        let id = namespaced(provider.id)
        let wrapped = NamespacedHoverProvider(base: provider, id: id)
        await registry.register(wrapped)
        return ExtensionRegistrationToken { [registry] in
            Task { await registry.unregister(id: id) }
        }
    }

    public func register(_ provider: any DiagnosticsProvider) async -> any ExtensionDisposable {
        let id = namespaced(provider.id)
        let wrapped = NamespacedDiagnosticsProvider(base: provider, id: id)
        await registry.register(wrapped)
        return ExtensionRegistrationToken { [registry] in
            Task { await registry.unregister(id: id) }
        }
    }

    public func register(_ provider: any FormattingProvider) async -> any ExtensionDisposable {
        let id = namespaced(provider.id)
        let wrapped = NamespacedFormattingProvider(base: provider, id: id)
        await registry.register(wrapped)
        return ExtensionRegistrationToken { [registry] in
            Task { await registry.unregister(id: id) }
        }
    }

    public func register(_ provider: any DefinitionProvider) async -> any ExtensionDisposable {
        let id = namespaced(provider.id)
        let wrapped = NamespacedDefinitionProvider(base: provider, id: id)
        await registry.register(wrapped)
        return ExtensionRegistrationToken { [registry] in
            Task { await registry.unregister(id: id) }
        }
    }

    private func namespaced(_ id: ProviderID) -> ProviderID {
        let raw = id.rawValue
        if raw.hasPrefix(extensionID.rawValue + ".") {
            return id
        }
        return ProviderID(rawValue: "\(extensionID.rawValue).\(raw)")
    }
}

// MARK: - Namespaced provider wrappers

private struct NamespacedCompletionProvider: CompletionProvider {
    let base: any CompletionProvider
    let id: ProviderID
    var selector: DocumentSelector { base.selector }
    var priority: Int { base.priority }
    func completions(for request: CompletionRequest) async throws -> CompletionList {
        try await base.completions(for: request)
    }
}

private struct NamespacedHoverProvider: HoverProvider {
    let base: any HoverProvider
    let id: ProviderID
    var selector: DocumentSelector { base.selector }
    var priority: Int { base.priority }
    func hover(for request: PositionRequest) async throws -> Hover? {
        try await base.hover(for: request)
    }
}

private struct NamespacedDiagnosticsProvider: DiagnosticsProvider {
    let base: any DiagnosticsProvider
    let id: ProviderID
    var selector: DocumentSelector { base.selector }
    var priority: Int { base.priority }
    func diagnostics(for request: DocumentRequest) async throws -> [LanguageDiagnostic] {
        try await base.diagnostics(for: request)
    }
}

private struct NamespacedFormattingProvider: FormattingProvider {
    let base: any FormattingProvider
    let id: ProviderID
    var selector: DocumentSelector { base.selector }
    var priority: Int { base.priority }
    func format(
        _ request: DocumentRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        try await base.format(request, options: options)
    }
}

private struct NamespacedDefinitionProvider: DefinitionProvider {
    let base: any DefinitionProvider
    let id: ProviderID
    var selector: DocumentSelector { base.selector }
    var priority: Int { base.priority }
    func definitions(for request: PositionRequest) async throws -> [LocationLink] {
        try await base.definitions(for: request)
    }
}

// MARK: - Panels / themes / snippets

public final class PanelContributionRegistrar: @unchecked Sendable {
    private let store: PanelContributionStore
    private let extensionID: ExtensionID
    private let granted: Set<ExtensionPermission>

    public init(
        store: PanelContributionStore,
        extensionID: ExtensionID,
        grantedPermissions: Set<ExtensionPermission>
    ) {
        self.store = store
        self.extensionID = extensionID
        self.granted = grantedPermissions
    }

    @discardableResult
    public func register(
        id: String,
        slot: String,
        title: String,
        priority: Int = 0
    ) throws -> any ExtensionDisposable {
        guard granted.contains(.presentUI) else {
            throw ExtensionError.permissionDenied(.presentUI)
        }
        let panelID = id.contains(".") ? id : "\(extensionID.rawValue).\(id)"
        let panel = PanelContribution(
            id: panelID,
            slot: slot,
            title: title,
            priority: priority,
            extensionID: extensionID
        )
        store.register(panel)
        return ExtensionRegistrationToken { [store] in
            store.unregister(id: panelID)
        }
    }
}

public final class ThemeContributionRegistrar: @unchecked Sendable {
    private let store: ThemeContributionStore
    private let extensionID: ExtensionID

    public init(store: ThemeContributionStore, extensionID: ExtensionID) {
        self.store = store
        self.extensionID = extensionID
    }

    @discardableResult
    public func register(_ theme: ThemeContribution) -> any ExtensionDisposable {
        var copy = theme
        copy.extensionID = extensionID
        if !copy.id.contains(".") {
            copy.id = "\(extensionID.rawValue).\(copy.id)"
        }
        let id = copy.id
        store.register(copy)
        return ExtensionRegistrationToken { [store] in
            store.unregister(id: id)
        }
    }
}

public final class SnippetContributionRegistrar: @unchecked Sendable {
    private let store: SnippetContributionStore
    private let extensionID: ExtensionID

    public init(store: SnippetContributionStore, extensionID: ExtensionID) {
        self.store = store
        self.extensionID = extensionID
    }

    @discardableResult
    public func register(_ snippet: SnippetContribution) -> any ExtensionDisposable {
        var copy = snippet
        copy.extensionID = extensionID
        if !copy.id.contains(".") {
            copy.id = "\(extensionID.rawValue).\(copy.id)"
        }
        let id = copy.id
        store.register(copy)
        return ExtensionRegistrationToken { [store] in
            store.unregister(id: id)
        }
    }
}

public final class IconThemeContributionRegistrar: @unchecked Sendable {
    private let store: IconThemeContributionStore
    private let extensionID: ExtensionID

    public init(store: IconThemeContributionStore, extensionID: ExtensionID) {
        self.store = store
        self.extensionID = extensionID
    }

    @discardableResult
    public func register(_ theme: IconThemeContribution) -> any ExtensionDisposable {
        var copy = theme
        copy.extensionID = extensionID
        if !copy.id.contains(".") {
            copy.id = "\(extensionID.rawValue).\(copy.id)"
        }
        let id = copy.id
        store.register(copy)
        return ExtensionRegistrationToken { [store] in
            store.unregister(id: id)
        }
    }
}
