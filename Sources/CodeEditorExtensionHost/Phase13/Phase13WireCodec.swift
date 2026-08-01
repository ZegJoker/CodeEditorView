import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol

/// Real Phase 13 `dap.*` / `mcp.*` / `slash.*` / `docs.*` wire dispatch — providers required, no canned payloads.
public enum Phase13WireCodec {
    public static func parseID(_ data: Data, keys: [String] = ["adapterID", "serverID", "commandID", "packageID", "id"]) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        for k in keys {
            if let s = obj[k] as? String, !s.isEmpty { return s }
        }
        return ""
    }

    public static func parseArguments(_ data: Data) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj?["arguments"] as? String ?? obj?["args"] as? String ?? ""
    }

    public static func dispatchDAP(
        method: ExtensionMethodID,
        payload: Data,
        provider: any DebugAdapterProvider,
        locator: (any DebugLocatorProvider)?,
        extensionID: ExtensionID,
        status: DebugAdapterStatus? = nil,
        onRestart: (@Sendable (String) async throws -> Void)? = nil
    ) async throws -> Data {
        let ctx = LanguageServerResolveContext(extensionID: extensionID)
        switch method {
        case .dapResolveLaunchPlan:
            let id = parseID(payload, keys: ["adapterID", "serverID", "id"])
            guard !id.isEmpty else { throw ExtensionWireError(code: -32602, message: "adapterID required") }
            let plan = try await provider.resolveLaunchPlan(adapterID: id, context: ctx)
            return try JSONEncoder().encode(plan)
        case .dapResolveConfigurations:
            let id = parseID(payload, keys: ["adapterID", "id"])
            guard !id.isEmpty else { throw ExtensionWireError(code: -32602, message: "adapterID required") }
            let configs = try await provider.resolveConfigurations(adapterID: id, context: ctx)
            return try JSONEncoder().encode(configs)
        case .dapLocate:
            guard let locator else {
                throw ExtensionWireError.methodNotFound
            }
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let locateCtx = DebugLocatorContext(
                extensionID: extensionID,
                uri: obj["uri"] as? String,
                languageID: obj["languageID"] as? String,
                workspaceRootPaths: obj["workspaceRootPaths"] as? [String] ?? []
            )
            let matches = try await locator.locate(context: locateCtx)
            return try JSONEncoder().encode(matches)
        case .dapStatus:
            if let status {
                return try JSONEncoder().encode(status)
            }
            throw ExtensionWireError(code: -32004, message: "no status for adapter")
        case .dapRestart:
            let id = parseID(payload, keys: ["adapterID", "id"])
            guard !id.isEmpty else { throw ExtensionWireError(code: -32602, message: "adapterID required") }
            guard let onRestart else {
                throw ExtensionWireError(code: -32004, message: "restart not wired")
            }
            try await onRestart(id)
            return try JSONSerialization.data(withJSONObject: ["ok": true, "adapterID": id])
        default:
            throw ExtensionWireError.methodNotFound
        }
    }

    public static func dispatchMCP(
        method: ExtensionMethodID,
        payload: Data,
        provider: any MCPServerProvider,
        extensionID: ExtensionID,
        status: MCPServerStatus? = nil,
        onRestart: (@Sendable (String) async throws -> Void)? = nil
    ) async throws -> Data {
        let ctx = LanguageServerResolveContext(extensionID: extensionID)
        switch method {
        case .mcpResolveLaunchPlan:
            let id = parseID(payload, keys: ["serverID", "id"])
            guard !id.isEmpty else { throw ExtensionWireError(code: -32602, message: "serverID required") }
            let plan = try await provider.resolveLaunchPlan(serverID: id, context: ctx)
            return try JSONEncoder().encode(plan)
        case .mcpStatus:
            if let status {
                return try JSONEncoder().encode(status)
            }
            throw ExtensionWireError(code: -32004, message: "no status for MCP server")
        case .mcpRestart:
            let id = parseID(payload, keys: ["serverID", "id"])
            guard !id.isEmpty else { throw ExtensionWireError(code: -32602, message: "serverID required") }
            guard let onRestart else {
                throw ExtensionWireError(code: -32004, message: "restart not wired")
            }
            try await onRestart(id)
            return try JSONSerialization.data(withJSONObject: ["ok": true, "serverID": id])
        default:
            throw ExtensionWireError.methodNotFound
        }
    }

    public static func dispatchSlash(
        method: ExtensionMethodID,
        payload: Data,
        provider: any SlashCommandProvider,
        extensionID: ExtensionID,
        worktreeRoot: String? = nil
    ) async throws -> Data {
        guard method == .slashExecute else { throw ExtensionWireError.methodNotFound }
        let commandID = parseID(payload, keys: ["commandID", "id"])
        guard !commandID.isEmpty else {
            throw ExtensionWireError(code: -32602, message: "commandID required")
        }
        let arguments = parseArguments(payload)
        let ctx = SlashCommandExecuteContext(extensionID: extensionID, worktreeRoot: worktreeRoot)
        var chunks: [SlashCommandChunk] = []
        for try await chunk in provider.execute(commandID: commandID, arguments: arguments, context: ctx) {
            let safe = SlashCommandChunk(
                markdown: SlashCommandSanitize.sanitizeMarkdown(chunk.markdown),
                isFinal: chunk.isFinal
            )
            chunks.append(safe)
        }
        return try JSONEncoder().encode(chunks)
    }

    public static func dispatchDocs(
        method: ExtensionMethodID,
        payload: Data,
        provider: any DocumentationIndexProvider,
        extensionID: ExtensionID
    ) async throws -> Data {
        let ctx = LanguageServerResolveContext(extensionID: extensionID)
        switch method {
        case .docsSuggest:
            let suggestions = try await provider.suggestPackages(context: ctx)
            return try JSONEncoder().encode(suggestions)
        case .docsBuildIndex:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let packageID = obj["packageID"] as? String ?? obj["id"] as? String ?? ""
            guard !packageID.isEmpty else {
                throw ExtensionWireError(code: -32602, message: "packageID required")
            }
            let title = obj["title"] as? String ?? packageID
            let suggestion = DocumentationPackageSuggestion(
                id: packageID,
                title: title,
                languages: obj["languages"] as? [String] ?? [],
                sourcePath: obj["sourcePath"] as? String,
                downloadURL: obj["downloadURL"] as? String,
                downloadDigest: obj["downloadDigest"] as? String
            )
            var progress: [DocumentationIndexProgress] = []
            var entries: [DocumentationIndexEntry] = []
            for try await event in provider.buildIndex(package: suggestion, context: ctx) {
                switch event {
                case .progress(let p): progress.append(p)
                case .entry(let e): entries.append(e)
                case .completed: break
                }
            }
            if entries.isEmpty {
                throw DocumentationIndexError.notFound(packageID)
            }
            return try JSONEncoder().encode(DocumentationBuildResult(progress: progress, entries: entries))
        case .docsInvalidate:
            let packageID = parseID(payload, keys: ["packageID", "id"])
            await provider.invalidate(packageID: packageID.isEmpty ? nil : packageID)
            return try JSONSerialization.data(withJSONObject: [
                "ok": true,
                "packageID": packageID as Any,
            ])
        default:
            throw ExtensionWireError.methodNotFound
        }
    }
}

public struct DocumentationBuildResult: Sendable, Hashable, Codable {
    public var progress: [DocumentationIndexProgress]
    public var entries: [DocumentationIndexEntry]
    public init(progress: [DocumentationIndexProgress], entries: [DocumentationIndexEntry]) {
        self.progress = progress
        self.entries = entries
    }
}
