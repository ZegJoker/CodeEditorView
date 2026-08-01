import Foundation
import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorLanguageServices
import CodeEditorLSP

/// Host-side language-server lifecycle: providers, language maps, start/stop/restart, settings invalidation.
public actor LanguageServerCoordinator {
    public let executor: LanguageServerLaunchPlanExecutor
    private var providers: [ExtensionID: any LanguageServerProvider] = [:]
    private var activeKeys: Set<String> = []
    private var settingsWatchKeys: [String: Set<String>] = [:] // serverID → setting keys
    private var languageMap = LanguageServerLanguageMap()

    public init(executor: LanguageServerLaunchPlanExecutor) {
        self.executor = executor
    }

    public func registerProvider(_ provider: any LanguageServerProvider, extensionID: ExtensionID) {
        providers[extensionID] = provider
    }

    public func unregisterProvider(extensionID: ExtensionID) {
        providers[extensionID] = nil
    }

    public func registerContribution(_ contribution: LanguageServerContribution) {
        languageMap.register(serverID: contribution.serverID, languages: contribution.languages)
    }

    public func registerLanguages(serverID: String, languages: [String]) {
        languageMap.register(serverID: serverID, languages: languages)
    }

    public func servers(forLanguage languageID: String) -> [String] {
        languageMap.servers(forLanguage: languageID)
    }

    public func currentLanguageMap() -> LanguageServerLanguageMap {
        languageMap
    }

    public func provider(for extensionID: ExtensionID) -> (any LanguageServerProvider)? {
        providers[extensionID]
    }

    /// Resolve via provider (or seed plan), materialize, start LSP, wire hooks.
    @discardableResult
    public func start(
        serverID: String,
        extensionID: ExtensionID,
        registry: LanguageServiceRegistry,
        workspaceRoots: [URL] = [],
        seedPlan: LanguageServerLaunchPlan? = nil,
        settingsWatch: Set<String> = ["toolchain", "languageServer.path", "lsp.path"]
    ) async throws -> LanguageServerSession {
        let provider = providers[extensionID]
        let broker = await executor.broker
        let ctx = try await LanguageServerResolveContextBuilder.build(
            extensionID: extensionID,
            broker: broker,
            workspaceRoots: workspaceRoots,
            whichNames: seedPlan.map { [$0.command] } ?? [serverID]
        )
        let plan: LanguageServerLaunchPlan
        if let provider {
            plan = try await provider.resolveLaunchPlan(serverID: serverID, context: ctx)
        } else if let seedPlan {
            plan = seedPlan
        } else {
            throw LanguageServerProviderError.unknownServer(serverID)
        }
        languageMap.register(serverID: plan.serverID, languages: plan.languages)
        settingsWatchKeys[serverID] = settingsWatch
        let session = try await executor.start(
            plan: plan,
            extensionID: extensionID,
            registry: registry,
            workspaceRoots: workspaceRoots,
            provider: provider
        )
        activeKeys.insert(key(extensionID: extensionID, serverID: serverID))
        return session
    }

    public func stop(serverID: String, extensionID: ExtensionID) async {
        await executor.stop(serverID: serverID, extensionID: extensionID)
        activeKeys.remove(key(extensionID: extensionID, serverID: serverID))
        settingsWatchKeys[serverID] = nil
    }

    public func restart(serverID: String) async throws {
        try await executor.restart(serverID: serverID)
    }

    /// Invalidate / restart servers when settings or toolchain change (§8.5).
    public func notifySettingsChanged(
        extensionID: ExtensionID,
        changedKeys: Set<String>,
        registry: LanguageServiceRegistry,
        workspaceRoots: [URL] = []
    ) async throws {
        let affected = settingsWatchKeys.filter { _, keys in
            !keys.isDisjoint(with: changedKeys)
        }.map(\.key)
        for serverID in affected {
            let k = key(extensionID: extensionID, serverID: serverID)
            guard activeKeys.contains(k) else { continue }
            // Full re-resolve: stop then start with fresh context
            await stop(serverID: serverID, extensionID: extensionID)
            _ = try await start(
                serverID: serverID,
                extensionID: extensionID,
                registry: registry,
                workspaceRoots: workspaceRoots
            )
        }
    }

    /// Wire `ls.*` methods for built-in / guest provider dispatch.
    public func dispatch(
        method: ExtensionMethodID,
        extensionID: ExtensionID,
        payload: Data
    ) async throws -> Data {
        guard let provider = providers[extensionID] else {
            throw ExtensionWireError.methodNotFound
        }
        let statusStore = await executor.statusStore
        let serverID = LanguageServerWireCodec.parseServerID(payload)
        let status = await statusStore.status(serverID: serverID.isEmpty ? "unknown" : serverID, extensionID: extensionID)
        if method == .lsRestart {
            if !serverID.isEmpty {
                try await restart(serverID: serverID)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        if method == .lsStatus {
            if let status {
                return try JSONEncoder().encode(status)
            }
            return Data(#"{"state":"idle"}"#.utf8)
        }
        return try await LanguageServerWireCodec.dispatch(
            method: method,
            payload: payload,
            provider: provider,
            extensionID: extensionID,
            status: status
        )
    }

    private func key(extensionID: ExtensionID, serverID: String) -> String {
        "\(extensionID.rawValue)::\(serverID)"
    }
}
