import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLanguageSupport

/// Disposable that unregisters LSP-backed providers.
public final class LSPProviderRegistration: @unchecked Sendable {
    private let registry: LanguageServiceRegistry
    private let ids: [ProviderID]
    private var disposed = false
    private let lock = NSLock()

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

/// Registers LanguageServices providers that forward to an LSP session.
public enum LSPClientProviders {
    public static func register(
        session: LanguageServerSession,
        into registry: LanguageServiceRegistry,
        selector: DocumentSelector = .any,
        priority: Int = 100
    ) async -> LSPProviderRegistration {
        let baseID = await session.id.rawValue
        let caps = await session.capabilities
        var ids: [ProviderID] = []

        if caps.completion {
            let p = LSPCompletionAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).completion"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.hover {
            let p = LSPHoverAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).hover"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.definition {
            let p = LSPDefinitionAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).definition"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.diagnostics {
            let p = LSPDiagnosticsAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).diagnostics"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.formatting || caps.rangeFormatting {
            let p = LSPFormattingAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).formatting"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.rename {
            let p = LSPRenameAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).rename"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.documentSymbol {
            let p = LSPDocumentSymbolAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).symbols"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }
        if caps.semanticTokens {
            let p = LSPSemanticTokensAdapter(
                session: session,
                id: ProviderID(rawValue: "\(baseID).semantic"),
                selector: selector,
                priority: priority
            )
            await registry.register(p)
            ids.append(p.id)
        }

        return LSPProviderRegistration(registry: registry, ids: ids)
    }
}

// MARK: - Shared helpers

private enum LSPRequestHelpers {
    static func positionParams(
        uri: DocumentURI?,
        position: TextPosition,
        text: String
    ) -> [String: Any] {
        let pos = LSPConvert.position(position, in: text)
        return [
            "textDocument": ["uri": uri?.rawValue ?? ""],
            "position": ["line": pos.line, "character": pos.character],
        ]
    }

    static func decodeEdits(_ result: LSPJSONObject, text: String) throws -> [TextEditPlan] {
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let data = try JSONSerialization.data(withJSONObject: arr)
        let edits = try JSONDecoder().decode([LSPTextEdit].self, from: data)
        return edits.map { LSPConvert.textEditPlan($0, in: text) }
    }
}

// MARK: - Adapters

struct LSPCompletionAdapter: CompletionProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func completions(for request: CompletionRequest) async throws -> CompletionList {
        var params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text
        )
        params["context"] = ["triggerKind": 1]
        let result = try await session.requestDictionary(
            "textDocument/completion",
            params: LSPJSONObject(params)
        )
        let text = request.document.text
        if let items = result["_value"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: items)
            let decoded = try JSONDecoder().decode([LSPCompletionItem].self, from: data)
            return CompletionList(items: decoded.map { LSPConvert.completionItem($0, in: text) })
        }
        if let itemDicts = result["items"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: itemDicts)
            let decoded = try JSONDecoder().decode([LSPCompletionItem].self, from: data)
            let incomplete = result["isIncomplete"] as? Bool ?? false
            return CompletionList(
                isIncomplete: incomplete,
                items: decoded.map { LSPConvert.completionItem($0, in: text) }
            )
        }
        return .empty
    }
}

// Note: result is LSPJSONObject (Sendable).

struct LSPHoverAdapter: HoverProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func hover(for request: PositionRequest) async throws -> Hover? {
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text
        )
        guard let hover: LSPHover = try await session.requestOptionalJSON(
            "textDocument/hover",
            params: LSPJSONObject(params)
        ) else { return nil }
        let text = request.document.text
        let section: HoverSection
        switch hover.contents {
        case .markup(let m):
            section = HoverSection(
                content: MarkupContent(
                    kind: m.kind == "markdown" ? .markdown : .plaintext,
                    value: m.value
                ),
                range: hover.range.map { LSPConvert.textRange($0, in: text) }
            )
        case .markedString(let s):
            section = HoverSection(
                content: .markdown(s),
                range: hover.range.map { LSPConvert.textRange($0, in: text) }
            )
        case .markedStringArray(let arr):
            section = HoverSection(
                content: .markdown(arr.joined(separator: "\n\n")),
                range: hover.range.map { LSPConvert.textRange($0, in: text) }
            )
        }
        return Hover(sections: [section])
    }
}

struct LSPDefinitionAdapter: DefinitionProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func definitions(for request: PositionRequest) async throws -> [LocationLink] {
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text
        )
        let result = try await session.requestDictionary(
            "textDocument/definition",
            params: LSPJSONObject(params)
        )
        let text = request.document.text
        if let arr = result["_value"] as? [[String: Any]] {
            return arr.compactMap { parseLocationLink(from: $0, text: text) }
        }
        if let link = parseLocationLink(from: result.dictionary, text: text) {
            return [link]
        }
        return []
    }

    private func parseLocationLink(from dict: [String: Any], text: String) -> LocationLink? {
        // LocationLink shape
        if let targetUri = dict["targetUri"] as? String,
           let targetRange = parseLSPRange(dict["targetRange"])
        {
            let sel = parseLSPRange(dict["targetSelectionRange"]) ?? targetRange
            return LocationLink(
                targetURI: DocumentURI(rawValue: targetUri),
                targetRange: LSPConvert.textRange(targetRange, in: text),
                targetSelectionRange: LSPConvert.textRange(sel, in: text)
            )
        }
        // Location shape
        if let uri = dict["uri"] as? String, let range = parseLSPRange(dict["range"]) {
            let tr = LSPConvert.textRange(range, in: text)
            return LocationLink(
                targetURI: DocumentURI(rawValue: uri),
                targetRange: tr,
                targetSelectionRange: tr
            )
        }
        return nil
    }

    private func parseLSPRange(_ any: Any?) -> LSPRange? {
        guard let dict = any as? [String: Any],
              let start = dict["start"] as? [String: Any],
              let end = dict["end"] as? [String: Any]
        else { return nil }
        func pos(_ d: [String: Any]) -> LSPPosition? {
            let line = (d["line"] as? Int) ?? (d["line"] as? NSNumber)?.intValue
            let character = (d["character"] as? Int) ?? (d["character"] as? NSNumber)?.intValue
            guard let line, let character else { return nil }
            return LSPPosition(line: line, character: character)
        }
        guard let s = pos(start), let e = pos(end) else { return nil }
        return LSPRange(start: s, end: e)
    }
}

struct LSPDiagnosticsAdapter: DiagnosticsProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func diagnostics(for request: DocumentRequest) async throws -> [LanguageDiagnostic] {
        _ = request
        // Prefer `session.diagnosticsStream` for push diagnostics.
        return []
    }
}

struct LSPFormattingAdapter: FormattingProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func format(
        _ request: DocumentRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""],
            "options": [
                "tabSize": options.tabSize,
                "insertSpaces": options.insertSpaces,
            ],
        ]
        let result = try await session.requestDictionary(
            "textDocument/formatting",
            params: LSPJSONObject(params)
        )
        return try LSPRequestHelpers.decodeEdits(result, text: request.document.text)
    }
}

struct LSPRenameAdapter: RenameProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func rename(
        _ request: PositionRequest,
        newName: String
    ) async throws -> WorkspaceEditPlan {
        var params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text
        )
        params["newName"] = newName
        let result = try await session.requestDictionary(
            "textDocument/rename",
            params: LSPJSONObject(params)
        )
        guard let changes = result.dictionary["changes"] as? [String: [[String: Any]]] else {
            return WorkspaceEditPlan()
        }
        var docs: [DocumentEditPlan] = []
        let text = request.document.text
        for (uri, editsDict) in changes {
            let data = try JSONSerialization.data(withJSONObject: editsDict)
            let edits = try JSONDecoder().decode([LSPTextEdit].self, from: data)
            docs.append(
                DocumentEditPlan(
                    uri: DocumentURI(rawValue: uri),
                    edits: edits.map { LSPConvert.textEditPlan($0, in: text) }
                )
            )
        }
        return WorkspaceEditPlan(documentEdits: docs)
    }
}

struct LSPDocumentSymbolAdapter: DocumentSymbolProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func documentSymbols(for request: DocumentRequest) async throws -> [DocumentSymbol] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""],
        ]
        let result = try await session.requestDictionary(
            "textDocument/documentSymbol",
            params: LSPJSONObject(params)
        )
        guard let arr = result.dictionary["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> DocumentSymbol? in
            guard let name = dict["name"] as? String else { return nil }
            guard let rangeDict = dict["range"] as? [String: Any],
                  let selDict = dict["selectionRange"] as? [String: Any],
                  let rangeData = try? JSONSerialization.data(withJSONObject: rangeDict),
                  let selData = try? JSONSerialization.data(withJSONObject: selDict),
                  let range = try? JSONDecoder().decode(LSPRange.self, from: rangeData),
                  let sel = try? JSONDecoder().decode(LSPRange.self, from: selData)
            else { return nil }
            return DocumentSymbol(
                name: name,
                kind: .function,
                range: LSPConvert.textRange(range, in: text),
                selectionRange: LSPConvert.textRange(sel, in: text)
            )
        }
    }
}

struct LSPSemanticTokensAdapter: SemanticTokensProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func semanticTokens(for request: DocumentRequest) async throws -> [SemanticTokenSpan] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""],
        ]
        guard let tokens: LSPSemanticTokens = try await session.requestOptionalJSON(
            "textDocument/semanticTokens/full",
            params: LSPJSONObject(params)
        ) else {
            return []
        }
        return decodeSemanticTokens(tokens.data, text: request.document.text)
    }

    private func decodeSemanticTokens(_ data: [UInt32], text: String) -> [SemanticTokenSpan] {
        var spans: [SemanticTokenSpan] = []
        var line = 0
        var char = 0
        var i = 0
        let legend = [
            "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
            "parameter", "variable", "property", "enumMember", "event", "function", "method",
            "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
        ]
        while i + 4 < data.count {
            let deltaLine = Int(data[i])
            let deltaStart = Int(data[i + 1])
            let length = Int(data[i + 2])
            let typeIndex = Int(data[i + 3])
            i += 5
            if deltaLine == 0 {
                char += deltaStart
            } else {
                line += deltaLine
                char = deltaStart
            }
            let start = LSPConvert.utf16Offset(line: line, character: char, in: text)
            let range = CodeEditorCore.TextRange(location: start, length: length)
            let typeName = typeIndex < legend.count ? legend[typeIndex] : nil
            spans.append(
                SemanticTokenSpan(
                    range: range,
                    capture: LSPConvert.captureName(tokenType: typeName),
                    rawType: typeName,
                    providerID: id.rawValue
                )
            )
        }
        return spans
    }
}
