import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensions
import CodeEditorLanguageServices
import Foundation

/// Registers remote-backed providers for one extension process.
public final class RemoteProviderRegistration: @unchecked Sendable {
    private let registry: LanguageServiceRegistry
    private let ids: [ProviderID]
    private let lock = NSLock()
    private var disposed = false

    init(registry: LanguageServiceRegistry, ids: [ProviderID]) {
        self.registry = registry
        self.ids = ids
    }

    public func dispose() {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        lock.unlock()
        let registry = self.registry
        let ids = self.ids
        Task {
            for id in ids {
                await registry.unregister(id: id)
            }
        }
    }

    deinit { dispose() }
}

public enum RemoteLanguageServiceProviders {
    public static func register(
        process: RemoteExtensionProcess,
        extensionID: ExtensionID,
        into registry: LanguageServiceRegistry,
        selector: DocumentSelector = .any,
        priority: Int = 50
    ) async -> RemoteProviderRegistration {
        let prefix = "remote.\(extensionID.rawValue)"
        var ids: [ProviderID] = []

        let completion = RemoteCompletionProvider(
            process: process,
            id: ProviderID(rawValue: "\(prefix).completion"),
            selector: selector,
            priority: priority
        )
        await registry.register(completion)
        ids.append(completion.id)

        let hover = RemoteHoverProvider(
            process: process,
            id: ProviderID(rawValue: "\(prefix).hover"),
            selector: selector,
            priority: priority
        )
        await registry.register(hover)
        ids.append(hover.id)

        let definition = RemoteDefinitionProvider(
            process: process,
            id: ProviderID(rawValue: "\(prefix).definition"),
            selector: selector,
            priority: priority
        )
        await registry.register(definition)
        ids.append(definition.id)

        return RemoteProviderRegistration(registry: registry, ids: ids)
    }
}

// MARK: - Codable request DTOs

struct RemotePositionPayload: Codable, Sendable {
    var text: String
    var version: UInt64
    var utf16Offset: Int
    var languageID: String?
    var uri: String?
}

struct RemoteCompletionProvider: CompletionProvider {
    let process: RemoteExtensionProcess
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func completions(for request: CompletionRequest) async throws -> CompletionList {
        let payload = RemotePositionPayload(
            text: request.document.text,
            version: request.document.version.rawValue,
            utf16Offset: request.position.utf16Offset,
            languageID: request.context.languageID,
            uri: request.context.uri?.rawValue
        )
        let data = try ExtensionRPCCodec.encodePayload(payload)
        let result = try await process.call(.completion, payload: data)
        return try ExtensionRPCCodec.decodePayload(result, as: CompletionList.self)
    }
}

struct RemoteHoverProvider: HoverProvider {
    let process: RemoteExtensionProcess
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func hover(for request: PositionRequest) async throws -> Hover? {
        let payload = RemotePositionPayload(
            text: request.document.text,
            version: request.document.version.rawValue,
            utf16Offset: request.position.utf16Offset,
            languageID: request.context.languageID,
            uri: request.context.uri?.rawValue
        )
        let data = try ExtensionRPCCodec.encodePayload(payload)
        let result = try await process.call(.hover, payload: data)
        if result.isEmpty { return nil }
        return try ExtensionRPCCodec.decodePayload(result, as: Hover.self)
    }
}

struct RemoteDefinitionProvider: DefinitionProvider {
    let process: RemoteExtensionProcess
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func definitions(for request: PositionRequest) async throws -> [LocationLink] {
        let payload = RemotePositionPayload(
            text: request.document.text,
            version: request.document.version.rawValue,
            utf16Offset: request.position.utf16Offset,
            languageID: request.context.languageID,
            uri: request.context.uri?.rawValue
        )
        let data = try ExtensionRPCCodec.encodePayload(payload)
        let result = try await process.call(.definition, payload: data)
        if result.isEmpty { return [] }
        return try ExtensionRPCCodec.decodePayload(result, as: [LocationLink].self)
    }
}
