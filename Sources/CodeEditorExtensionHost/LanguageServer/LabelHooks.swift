import CodeEditorExtensionAPI
import CodeEditorLanguageServices
import Foundation

/// Applies extension label transforms to LSP-decoded items.
public actor LanguageServerLabelHookRegistry {
    private var completionHooks: [String: @Sendable (CompletionLabelTransform) async -> CompletionLabelTransform] = [:]
    private var symbolHooks: [String: @Sendable (SymbolLabelTransform) async -> SymbolLabelTransform] = [:]

    public init() {}

    public func registerCompletion(
        serverID: String,
        hook: @escaping @Sendable (CompletionLabelTransform) async -> CompletionLabelTransform
    ) {
        completionHooks[serverID] = hook
    }

    public func registerSymbol(
        serverID: String,
        hook: @escaping @Sendable (SymbolLabelTransform) async -> SymbolLabelTransform
    ) {
        symbolHooks[serverID] = hook
    }

    public func unregister(serverID: String) {
        completionHooks[serverID] = nil
        symbolHooks[serverID] = nil
    }

    public func transformCompletion(serverID: String, item: CompletionItem) async -> CompletionItem {
        guard let hook = completionHooks[serverID] else { return item }
        let t = await hook(
            CompletionLabelTransform(
                label: item.label,
                detail: item.detail,
                insertText: item.insertText,
                filterText: item.filterText
            ))
        var copy = item
        copy.label = t.label
        copy.detail = t.detail
        copy.insertText = t.insertText
        copy.filterText = t.filterText
        return copy
    }

    public func transformSymbol(
        serverID: String, name: String, detail: String?, container: String?
    ) async -> (String, String?, String?) {
        guard let hook = symbolHooks[serverID] else { return (name, detail, container) }
        let t = await hook(SymbolLabelTransform(name: name, detail: detail, containerName: container))
        return (t.name, t.detail, t.containerName)
    }
}
