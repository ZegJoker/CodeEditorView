import CodeEditorExtensionAPI
import Foundation

/// Builds a fully populated ``LanguageServerResolveContext`` from broker handles (§8.5).
public enum LanguageServerResolveContextBuilder {
    public static func build(
        extensionID: ExtensionID,
        broker: CapabilityBroker,
        workspaceRoots: [URL] = [],
        whichNames: [String] = [],
        environmentNames: Set<String> = CapabilityBroker.defaultAllowedEnvironmentNames,
        platform: ExtensionPlatformInfo = .current
    ) async throws -> LanguageServerResolveContext {
        var worktree: WorktreeHandleID?
        var project: ProjectHandleID?
        var settings: SettingsHandleID?
        var storage: StorageHandleID?
        var settingsValues: [String: String] = [:]
        var environmentValues: [String: String] = [:]
        var whichResults: [String: String] = [:]
        var projectMetadata = ProjectMetadataSnapshot(
            rootPaths: workspaceRoots.map(\.path)
        )

        if let wh = try? await broker.worktreeHandle(extensionID: extensionID) {
            worktree = WorktreeHandleID(rawValue: wh.id.rawValue)
            if !environmentNames.isEmpty {
                environmentValues =
                    (try? await broker.worktreeEnvironment(
                        caller: extensionID,
                        handle: wh.id,
                        names: environmentNames
                    )) ?? [:]
            }
            for name in whichNames {
                if let path = try? await broker.worktreeWhich(
                    caller: extensionID, handle: wh.id, name: name
                ) {
                    whichResults[name] = path
                }
            }
        }
        if let ph = try? await broker.projectHandle(extensionID: extensionID) {
            project = ProjectHandleID(rawValue: ph.id.rawValue)
            if let info = try? await broker.projectInfo(caller: extensionID, handle: ph.id) {
                projectMetadata = ProjectMetadataSnapshot(
                    name: info.name,
                    rootPaths: info.roots.map(\.path)
                )
            }
        }
        if let sh = try? await broker.settingsHandle(extensionID: extensionID) {
            settings = SettingsHandleID(rawValue: sh.id.rawValue)
            // Snapshot common LS keys if present
            for key in ["toolchain", "languageServer.path", "lsp.path", "server.path"] {
                if let v = try? await broker.settingsGet(
                    caller: extensionID, handle: sh.id, key: key
                ) {
                    settingsValues[key] = v
                }
            }
            // Also pull all stored settings for this extension
            // (settings store is keyed; settingsGet per-key only — merge known keys above)
        }
        if let st = try? await broker.storageHandle(extensionID: extensionID) {
            storage = StorageHandleID(rawValue: st.id.rawValue)
        }

        return LanguageServerResolveContext(
            platform: platform,
            extensionID: extensionID,
            worktree: worktree,
            project: project,
            settings: settings,
            storage: storage,
            settingsValues: settingsValues,
            workspaceRootPaths: workspaceRoots.map(\.path),
            environmentValues: environmentValues,
            whichResults: whichResults,
            projectMetadata: projectMetadata
        )
    }
}
