import Foundation
import CodeEditorExtensionAPI
import CodeEditorCommands
import CodeEditorLanguageSupport
import CodeEditorLanguageServices

/// In-process extension lifecycle manager.
public actor ExtensionRuntime {
    public let environment: HostEnvironment
    public let services: ExtensionHostServices
    public let log: ExtensionLog

    private struct Entry {
        var ext: any CodeEditorExtension
        var permissionOverride: Set<ExtensionPermission>?
        var status: ExtensionStatus
        var context: ExtensionContext?
    }

    private var entries: [ExtensionID: Entry] = [:]

    public init(
        environment: HostEnvironment = .full,
        services: ExtensionHostServices,
        log: ExtensionLog = ExtensionLog()
    ) {
        self.environment = environment
        self.services = services
        self.log = log
    }

    // MARK: - Registration

    public func register(
        _ ext: any CodeEditorExtension,
        grantedPermissions override: Set<ExtensionPermission>? = nil
    ) {
        let manifest = ext.manifest
        let status = ExtensionStatus(
            id: manifest.id,
            displayName: manifest.displayName,
            state: .inactive(.registered),
            grantedPermissions: effectivePermissions(for: manifest, override: override)
        )
        entries[manifest.id] = Entry(
            ext: ext,
            permissionOverride: override,
            status: status,
            context: nil
        )
        log.append(
            extensionID: manifest.id,
            level: .info,
            message: "Registered \(manifest.displayName) \(manifest.version)"
        )
    }

    public func unregister(id: ExtensionID) async {
        if entries[id]?.status.state == .active || entries[id]?.context != nil {
            await deactivate(id: id)
        }
        entries.removeValue(forKey: id)
    }

    // MARK: - Activation

    public func fire(_ event: ExtensionActivationEvent) async {
        let candidates = entries.values.filter { entry in
            entry.ext.manifest.activationEvents.contains { $0.matches(event) }
        }
        for entry in candidates {
            let id = entry.ext.manifest.id
            if case .active = entries[id]?.status.state { continue }
            do {
                try await activate(id: id)
            } catch {
                // Status already recorded in activate
            }
        }
    }

    public func activate(id: ExtensionID) async throws {
        guard var entry = entries[id] else {
            throw ExtensionError.notRegistered
        }
        if case .active = entry.status.state {
            throw ExtensionError.alreadyActive
        }

        let manifest = entry.ext.manifest

        // Compatibility
        if !manifest.requiredAPIVersion.contains(environment.apiVersion) {
            entry.status.state = .inactive(.incompatibleAPI)
            entry.status.lastError = "API \(environment.apiVersion) outside \(manifest.requiredAPIVersion.min)"
            entries[id] = entry
            log.append(extensionID: id, level: .warning, message: entry.status.lastError ?? "incompatible API")
            throw ExtensionError.incompatibleAPI(
                required: "\(manifest.requiredAPIVersion.min)+",
                host: "\(environment.apiVersion)"
            )
        }
        let missing = manifest.requiredHostCapabilities.subtracting(environment.capabilities)
        if !missing.isEmpty {
            entry.status.state = .inactive(.missingCapabilities)
            entry.status.lastError = "Missing capabilities: \(missing.map(\.rawValue).sorted().joined(separator: ", "))"
            entries[id] = entry
            log.append(extensionID: id, level: .warning, message: entry.status.lastError ?? "missing capabilities")
            throw ExtensionError.missingCapabilities(missing)
        }

        let granted = effectivePermissions(for: manifest, override: entry.permissionOverride)
        entry.status.state = .activating
        entry.status.grantedPermissions = granted
        entry.status.lastError = nil
        entries[id] = entry

        let context = buildContext(extensionID: id, granted: granted)
        entry.context = context
        entries[id] = entry

        do {
            try await entry.ext.activate(in: context)
            entry.status.state = .active
            entries[id] = entry
            log.append(extensionID: id, level: .info, message: "Activated")
        } catch {
            context.teardown()
            cleanupStores(for: id)
            entry.context = nil
            entry.status.state = .failed(String(describing: error))
            entry.status.lastError = String(describing: error)
            entries[id] = entry
            log.append(extensionID: id, level: .error, message: "Activation failed: \(error)")
            throw ExtensionError.activationFailed(String(describing: error))
        }
    }

    public func deactivate(id: ExtensionID) async {
        guard var entry = entries[id] else { return }
        entry.status.state = .deactivating
        entries[id] = entry

        entry.context?.teardown()
        entry.context = nil
        cleanupStores(for: id)

        await entry.ext.deactivate()

        entry.status.state = .inactive(.deactivated)
        entries[id] = entry
        log.append(extensionID: id, level: .info, message: "Deactivated")
    }

    // MARK: - Status

    public func status(id: ExtensionID) -> ExtensionStatus? {
        entries[id]?.status
    }

    public func allStatuses() -> [ExtensionStatus] {
        entries.values.map(\.status).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    public var panelStore: PanelContributionStore { services.panelStore }
    public var themeStore: ThemeContributionStore { services.themeStore }
    public var snippetStore: SnippetContributionStore { services.snippetStore }
    public var iconThemeStore: IconThemeContributionStore { services.iconThemeStore }

    // MARK: - Private

    private func effectivePermissions(
        for manifest: ExtensionManifest,
        override: Set<ExtensionPermission>?
    ) -> Set<ExtensionPermission> {
        let grant = override ?? environment.grantedPermissions
        return manifest.requestedPermissions.intersection(grant)
    }

    private func buildContext(
        extensionID: ExtensionID,
        granted: Set<ExtensionPermission>
    ) -> ExtensionContext {
        let context = ExtensionContext(
            extensionID: extensionID,
            grantedPermissions: granted,
            log: log
        )

        if environment.capabilities.contains(.commands), let reg = services.commandRegistry {
            context.install(commands: CommandContributionRegistrar(registry: reg))
        }
        if environment.capabilities.contains(.keybindings), let reg = services.keybindingRegistry {
            context.install(keybindings: KeybindingContributionRegistrar(registry: reg))
        }
        if environment.capabilities.contains(.languages) {
            let langReg = services.languageRegistry ?? .shared
            context.install(languages: LanguageContributionRegistrar(registry: langReg))
        }
        if environment.capabilities.contains(.languageServices),
           let reg = services.languageServiceRegistry
        {
            context.install(
                languageServices: LanguageServiceContributionRegistrar(
                    registry: reg,
                    extensionID: extensionID
                )
            )
        }
        if environment.capabilities.contains(.panels) {
            context.install(
                panels: PanelContributionRegistrar(
                    store: services.panelStore,
                    extensionID: extensionID,
                    grantedPermissions: granted
                )
            )
        }
        if environment.capabilities.contains(.themes) {
            context.install(
                themes: ThemeContributionRegistrar(
                    store: services.themeStore,
                    extensionID: extensionID
                )
            )
        }
        if environment.capabilities.contains(.snippets) {
            context.install(
                snippets: SnippetContributionRegistrar(
                    store: services.snippetStore,
                    extensionID: extensionID
                )
            )
        }
        if environment.capabilities.contains(.themes) {
            context.install(
                iconThemes: IconThemeContributionRegistrar(
                    store: services.iconThemeStore,
                    extensionID: extensionID
                )
            )
        }
        if environment.capabilities.contains(.storage), let root = services.storageRoot {
            let dir = root.appendingPathComponent(extensionID.rawValue, isDirectory: true)
            context.install(
                storage: ExtensionStorage(
                    extensionID: extensionID,
                    rootDirectory: dir,
                    grantedPermissions: granted
                )
            )
        }

        return context
    }

    private func cleanupStores(for id: ExtensionID) {
        services.panelStore.unregister(extensionID: id)
        services.themeStore.unregister(extensionID: id)
        services.snippetStore.unregister(extensionID: id)
        services.iconThemeStore.unregister(extensionID: id)
    }
}
