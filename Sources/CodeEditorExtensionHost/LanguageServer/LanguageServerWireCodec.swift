import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol

/// Encode/decode Phase 12 `ls.*` wire payloads (JSON, Codable plans).
public enum LanguageServerWireCodec {
    public static func encodePlan(_ plan: LanguageServerLaunchPlan) throws -> Data {
        try JSONEncoder().encode(plan)
    }

    public static func decodePlan(_ data: Data) throws -> LanguageServerLaunchPlan {
        try JSONDecoder().decode(LanguageServerLaunchPlan.self, from: data)
    }

    public static func encodeResolveRequest(serverID: String, context: LanguageServerResolveContext) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "serverID": serverID,
            "extensionID": context.extensionID.rawValue,
            "workspaceRootPaths": context.workspaceRootPaths,
            "settingsValues": context.settingsValues,
            "environmentValues": context.environmentValues,
            "whichResults": context.whichResults,
            "platform": [
                "os": context.platform.os,
                "arch": context.platform.arch,
                "isSimulator": context.platform.isSimulator,
                "profileName": context.platform.profileName,
                "processLaunchAllowed": context.platform.processLaunchAllowed,
            ],
            "projectMetadata": [
                "name": context.projectMetadata.name,
                "rootPaths": context.projectMetadata.rootPaths,
            ],
        ])
    }

    public static func parseServerID(_ data: Data) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj?["serverID"] as? String ?? ""
    }

    public static func decodeCompletionLabel(_ data: Data) -> CompletionLabelTransform {
        if let t = try? JSONDecoder().decode(CompletionLabelTransform.self, from: data) {
            return t
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return CompletionLabelTransform(
            label: obj?["label"] as? String ?? "",
            detail: obj?["detail"] as? String,
            insertText: obj?["insertText"] as? String,
            filterText: obj?["filterText"] as? String
        )
    }

    public static func encodeCompletionLabel(_ item: CompletionLabelTransform) throws -> Data {
        try JSONEncoder().encode(item)
    }

    public static func decodeSymbolLabel(_ data: Data) -> SymbolLabelTransform {
        if let t = try? JSONDecoder().decode(SymbolLabelTransform.self, from: data) {
            return t
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return SymbolLabelTransform(
            name: obj?["name"] as? String ?? "",
            detail: obj?["detail"] as? String,
            containerName: obj?["containerName"] as? String
        )
    }

    public static func encodeSymbolLabel(_ item: SymbolLabelTransform) throws -> Data {
        try JSONEncoder().encode(item)
    }

    public static func decodeConfigurationItems(_ data: Data) -> [WorkspaceConfigurationItem] {
        if let items = try? JSONDecoder().decode([WorkspaceConfigurationItem].self, from: data) {
            return items
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.map {
            WorkspaceConfigurationItem(
                section: $0["section"] as? String,
                scopeURI: $0["scopeURI"] as? String ?? $0["scopeUri"] as? String
            )
        }
    }

    public static func encodeConfigurationResults(_ results: [Data?]) throws -> Data {
        let objs: [Any] = results.map { data -> Any in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) {
                return obj
            }
            return NSNull()
        }
        return try JSONSerialization.data(withJSONObject: objs)
    }

    /// Dispatch `ls.*` against a local ``LanguageServerProvider``.
    public static func dispatch(
        method: ExtensionMethodID,
        payload: Data,
        provider: any LanguageServerProvider,
        extensionID: ExtensionID,
        status: LanguageServerStatus? = nil
    ) async throws -> Data {
        switch method {
        case .lsResolveLaunchPlan:
            let serverID = parseServerID(payload)
            let ctx = LanguageServerResolveContext(extensionID: extensionID)
            let plan = try await provider.resolveLaunchPlan(serverID: serverID, context: ctx)
            return try encodePlan(plan)
        case .lsInitializationOptions:
            let serverID = parseServerID(payload)
            let ctx = LanguageServerResolveContext(extensionID: extensionID)
            let data = try await provider.initializationOptions(serverID: serverID, context: ctx)
            return data ?? Data("{}".utf8)
        case .lsWorkspaceConfiguration:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let serverID = obj?["serverID"] as? String ?? ""
            let itemsData = (obj?["items"] as? [[String: Any]]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            } ?? Data("[]".utf8)
            let items = decodeConfigurationItems(itemsData)
            let results = try await provider.workspaceConfiguration(serverID: serverID, items: items)
            return try encodeConfigurationResults(results)
        case .lsTransformCompletionLabel:
            let item = decodeCompletionLabel(payload)
            let out = await provider.transformCompletionLabel(item)
            return try encodeCompletionLabel(out)
        case .lsTransformSymbolLabel:
            let item = decodeSymbolLabel(payload)
            let out = await provider.transformSymbolLabel(item)
            return try encodeSymbolLabel(out)
        case .lsStatus:
            if let status {
                return try JSONEncoder().encode(status)
            }
            return Data(#"{"state":"idle"}"#.utf8)
        case .lsRestart:
            return Data(#"{"ok":true,"action":"restart"}"#.utf8)
        default:
            throw ExtensionWireError.methodNotFound
        }
    }
}
