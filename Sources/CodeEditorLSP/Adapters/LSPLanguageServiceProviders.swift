import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation

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

/// Optional post-decode completion label transform (Phase 12 extension hooks).
public typealias LSPCompletionLabelHook = @Sendable (CompletionItem) async -> CompletionItem

/// Optional symbol label transform: (name, detail, container) → transformed triple.
public typealias LSPSymbolLabelHook = @Sendable (String, String?, String?) async -> (String, String?, String?)

/// Registers LanguageServices providers that forward to an LSP session.
/// Only capabilities advertised by the server are registered — never silently unsupported.
public enum LSPClientProviders {
    public static func register(
        session: LanguageServerSession,
        into registry: LanguageServiceRegistry,
        selector: DocumentSelector = .any,
        priority: Int = 100,
        completionLabelHook: LSPCompletionLabelHook? = nil,
        symbolLabelHook: LSPSymbolLabelHook? = nil
    ) async -> LSPProviderRegistration {
        let baseID = await session.id.rawValue
        let caps = await session.capabilities
        var ids: [ProviderID] = []

        func add(_ idSuffix: String, register: (ProviderID) async -> Void) async {
            let id = ProviderID(rawValue: "\(baseID).\(idSuffix)")
            await register(id)
            ids.append(id)
        }

        if caps.completion {
            await add("completion") { id in
                await registry.register(
                    LSPCompletionAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        labelHook: completionLabelHook
                    ))
            }
        }
        if caps.hover {
            await add("hover") { id in
                await registry.register(
                    LSPHoverAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.definition {
            await add("definition") { id in
                await registry.register(
                    LSPDefinitionAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.declaration {
            await add("declaration") { id in
                await registry.register(
                    LSPDeclarationAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.implementation {
            await add("implementation") { id in
                await registry.register(
                    LSPImplementationAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.references {
            await add("references") { id in
                await registry.register(
                    LSPReferencesAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.diagnostics {
            await add("diagnostics") { id in
                await registry.register(
                    LSPDiagnosticsAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.pullDiagnostics {
            await add("pullDiagnostics") { id in
                await registry.register(
                    LSPPullDiagnosticsAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.formatting || caps.rangeFormatting {
            await add("formatting") { id in
                await registry.register(
                    LSPFormattingAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        supportsDocument: caps.formatting,
                        supportsRange: caps.rangeFormatting
                    ))
            }
        }
        if caps.rename {
            await add("rename") { id in
                await registry.register(
                    LSPRenameAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.documentSymbol {
            await add("symbols") { id in
                await registry.register(
                    LSPDocumentSymbolAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        labelHook: symbolLabelHook
                    ))
            }
        }
        if caps.workspaceSymbol {
            await add("workspaceSymbols") { id in
                await registry.register(
                    LSPWorkspaceSymbolAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        labelHook: symbolLabelHook
                    ))
            }
        }
        if caps.semanticTokens {
            await add("semantic") { id in
                await registry.register(
                    LSPSemanticTokensAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        supportsRange: caps.semanticTokensRange
                    ))
            }
        }
        if caps.codeAction {
            await add("codeAction") { id in
                await registry.register(
                    LSPCodeActionAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.signatureHelp {
            await add("signatureHelp") { id in
                await registry.register(
                    LSPSignatureHelpAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.inlayHint {
            await add("inlayHint") { id in
                await registry.register(
                    LSPInlayHintAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.foldingRange {
            await add("folding") { id in
                await registry.register(
                    LSPFoldingRangeAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.documentLink {
            await add("links") { id in
                await registry.register(
                    LSPDocumentLinkAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.documentColor {
            await add("colors") { id in
                await registry.register(
                    LSPDocumentColorAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.documentHighlight {
            await add("highlights") { id in
                await registry.register(
                    LSPDocumentHighlightAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.typeHierarchy {
            await add("typeHierarchy") { id in
                await registry.register(
                    LSPTypeHierarchyAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.callHierarchy {
            await add("callHierarchy") { id in
                await registry.register(
                    LSPCallHierarchyAdapter(session: session, id: id, selector: selector, priority: priority))
            }
        }
        if caps.executeCommand {
            await add("executeCommand") { id in
                await registry.register(
                    LSPExecuteCommandAdapter(
                        session: session,
                        id: id,
                        selector: selector,
                        priority: priority,
                        commands: Set(caps.supportedCommands)
                    ))
            }
        }

        return LSPProviderRegistration(registry: registry, ids: ids)
    }
}

// MARK: - Shared helpers

private enum LSPRequestHelpers {
    static func positionParams(
        uri: DocumentURI?,
        position: TextPosition,
        text: String,
        map: LSPPositionMap? = nil
    ) -> [String: Any] {
        let pos: LSPPosition
        if let map {
            let p = map.position(utf16Offset: position.utf16Offset)
            pos = LSPPosition(line: p.line, character: p.character)
        } else {
            pos = LSPConvert.position(position, in: text)
        }
        return [
            "textDocument": ["uri": uri?.rawValue ?? ""],
            "position": ["line": pos.line, "character": pos.character],
        ]
    }

    static func rangeParams(
        uri: DocumentURI?,
        range: CodeEditorCore.TextRange,
        text: String,
        map: LSPPositionMap? = nil
    ) -> [String: Any] {
        let start: LSPPosition
        let end: LSPPosition
        if let map {
            // DOC-N05: use stored end offset — never bare location+length (overflow-safe TextRange).
            let s = map.position(utf16Offset: range.location)
            let e = map.position(utf16Offset: range.endUTF16Offset)
            start = LSPPosition(line: s.line, character: s.character)
            end = LSPPosition(line: e.line, character: e.character)
        } else {
            start = LSPConvert.position(range.start, in: text)
            end = LSPConvert.position(range.end, in: text)
        }
        return [
            "textDocument": ["uri": uri?.rawValue ?? ""],
            "range": [
                "start": ["line": start.line, "character": start.character],
                "end": ["line": end.line, "character": end.character],
            ],
        ]
    }

    static func decodeEdits(_ result: LSPJSONObject, text: String) throws -> [TextEditPlan] {
        if let arr = result["_value"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: arr)
            let edits = try JSONDecoder().decode([LSPTextEdit].self, from: data)
            return edits.map { LSPConvert.textEditPlan($0, in: text) }
        }
        return []
    }

    /// Resolve target text fail-closed (LSP-N09). Must not soft-fallback to empty.
    static func parseLocationLink(
        from dict: [String: Any],
        textForURI: (DocumentURI) async throws -> String
    ) async throws -> LocationLink? {
        if let targetUri = dict["targetUri"] as? String,
            let targetRange = parseLSPRange(dict["targetRange"])
        {
            let uri = DocumentURI(rawValue: targetUri)
            let text = try await textForURI(uri)
            let sel = parseLSPRange(dict["targetSelectionRange"]) ?? targetRange
            return LocationLink(
                targetURI: uri,
                targetRange: LSPConvert.textRange(targetRange, in: text),
                targetSelectionRange: LSPConvert.textRange(sel, in: text)
            )
        }
        if let uriStr = dict["uri"] as? String, let range = parseLSPRange(dict["range"]) {
            let uri = DocumentURI(rawValue: uriStr)
            let text = try await textForURI(uri)
            let tr = LSPConvert.textRange(range, in: text)
            return LocationLink(
                targetURI: uri,
                targetRange: tr,
                targetSelectionRange: tr
            )
        }
        return nil
    }

    static func parseLocationLinks(
        _ result: LSPJSONObject,
        textForURI: (DocumentURI) async throws -> String
    ) async throws -> [LocationLink] {
        if let arr = result["_value"] as? [[String: Any]] {
            var out: [LocationLink] = []
            for dict in arr {
                if let link = try await parseLocationLink(from: dict, textForURI: textForURI) {
                    out.append(link)
                }
            }
            return out
        }
        if let link = try await parseLocationLink(from: result.dictionary, textForURI: textForURI) {
            return [link]
        }
        return []
    }

    static func parseLocations(
        _ result: LSPJSONObject,
        textForURI: (DocumentURI) async throws -> String
    ) async throws -> [Location] {
        if let arr = result["_value"] as? [[String: Any]] {
            var out: [Location] = []
            for dict in arr {
                guard let uriStr = dict["uri"] as? String, let range = parseLSPRange(dict["range"]) else {
                    continue
                }
                let uri = DocumentURI(rawValue: uriStr)
                let text = try await textForURI(uri)
                out.append(Location(uri: uri, range: LSPConvert.textRange(range, in: text)))
            }
            return out
        }
        return []
    }

    static func parseLSPRange(_ any: Any?) -> LSPRange? {
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

    static func requireCapability(_ enabled: Bool, _ name: String) throws {
        if !enabled {
            throw LSPError.capabilityUnavailable(name)
        }
    }
}

// MARK: - Adapters

struct LSPCompletionAdapter: CompletionProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int
    let labelHook: LSPCompletionLabelHook?

    func completions(for request: CompletionRequest) async throws -> CompletionList {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        var params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        params["context"] = ["triggerKind": 1]
        let result = try await session.requestDictionary(
            "textDocument/completion",
            params: LSPJSONObject(params)
        )
        let text = request.document.text
        var items: [CompletionItem] = []
        var incomplete = false
        if let raw = result["_value"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: raw)
            let decoded = try JSONDecoder().decode([LSPCompletionItem].self, from: data)
            items = decoded.map { LSPConvert.completionItem($0, in: text) }
        } else if let itemDicts = result["items"] as? [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: itemDicts)
            let decoded = try JSONDecoder().decode([LSPCompletionItem].self, from: data)
            incomplete = result["isIncomplete"] as? Bool ?? false
            items = decoded.map { LSPConvert.completionItem($0, in: text) }
        } else {
            return .empty
        }
        if let labelHook {
            var transformed: [CompletionItem] = []
            transformed.reserveCapacity(items.count)
            for item in items {
                transformed.append(await labelHook(item))
            }
            items = transformed
        }
        return CompletionList(isIncomplete: incomplete, items: items)
    }
}

struct LSPHoverAdapter: HoverProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func hover(for request: PositionRequest) async throws -> Hover? {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        guard
            let hover: LSPHover = try await session.requestOptionalJSON(
                "textDocument/hover",
                params: LSPJSONObject(params)
            )
        else { return nil }
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
        try await navigation(method: "textDocument/definition", request: request)
    }
}

struct LSPDeclarationAdapter: DeclarationProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func declarations(for request: PositionRequest) async throws -> [LocationLink] {
        try await navigation(method: "textDocument/declaration", request: request)
    }
}

struct LSPImplementationAdapter: ImplementationProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func implementations(for request: PositionRequest) async throws -> [LocationLink] {
        try await navigation(method: "textDocument/implementation", request: request)
    }
}

// Shared navigation for definition-like adapters (LSP-N09: requireText, never empty soft-fallback)
extension LSPDefinitionAdapter {
    fileprivate func navigation(method: String, request: PositionRequest) async throws -> [LocationLink] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(method, params: LSPJSONObject(params))
        return try await LSPRequestHelpers.parseLocationLinks(result) { uri in
            try await session.requireText(for: uri)
        }
    }
}

extension LSPDeclarationAdapter {
    fileprivate func navigation(method: String, request: PositionRequest) async throws -> [LocationLink] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(method, params: LSPJSONObject(params))
        return try await LSPRequestHelpers.parseLocationLinks(result) { uri in
            try await session.requireText(for: uri)
        }
    }
}

extension LSPImplementationAdapter {
    fileprivate func navigation(method: String, request: PositionRequest) async throws -> [LocationLink] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(method, params: LSPJSONObject(params))
        return try await LSPRequestHelpers.parseLocationLinks(result) { uri in
            try await session.requireText(for: uri)
        }
    }
}

struct LSPReferencesAdapter: ReferencesProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func references(
        for request: PositionRequest,
        includeDeclaration: Bool
    ) async throws -> [Location] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        var params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        params["context"] = ["includeDeclaration": includeDeclaration]
        let result = try await session.requestDictionary(
            "textDocument/references",
            params: LSPJSONObject(params)
        )
        return try await LSPRequestHelpers.parseLocations(result) { uri in
            try await session.requireText(for: uri)
        }
    }
}

struct LSPDiagnosticsAdapter: DiagnosticsProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func diagnostics(for request: DocumentRequest) async throws -> [LanguageDiagnostic] {
        _ = request
        // Push diagnostics arrive via `session.diagnosticsStream`.
        return []
    }
}

struct LSPPullDiagnosticsAdapter: PullDiagnosticsProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func pullDiagnostics(for request: DocumentRequest) async throws -> PullDiagnosticsResult {
        let caps = await session.capabilities
        try LSPRequestHelpers.requireCapability(caps.pullDiagnostics, "textDocument/diagnostic")
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        let result = try await session.requestDictionary(
            "textDocument/diagnostic",
            params: LSPJSONObject(params)
        )
        let kind = result["kind"] as? String ?? "full"
        let resultID = result["resultId"] as? String
        let itemsDict = result["items"] as? [[String: Any]] ?? []
        let text = request.document.text
        let data = try JSONSerialization.data(withJSONObject: itemsDict)
        let diags = (try? JSONDecoder().decode([LSPDiagnostic].self, from: data)) ?? []
        return PullDiagnosticsResult(
            kind: kind,
            resultID: resultID,
            items: diags.map { LSPConvert.diagnostic($0, in: text) }
        )
    }
}

struct LSPFormattingAdapter: FormattingProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int
    let supportsDocument: Bool
    let supportsRange: Bool

    func format(
        _ request: DocumentRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        try LSPRequestHelpers.requireCapability(supportsDocument, "textDocument/formatting")
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

    func formatRange(
        _ request: RangeRequest,
        options: FormattingOptions
    ) async throws -> [TextEditPlan] {
        try LSPRequestHelpers.requireCapability(supportsRange, "textDocument/rangeFormatting")
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        var params = LSPRequestHelpers.rangeParams(
            uri: request.context.uri,
            range: request.range,
            text: request.document.text,
            map: map
        )
        params["options"] = [
            "tabSize": options.tabSize,
            "insertSpaces": options.insertSpaces,
        ]
        let result = try await session.requestDictionary(
            "textDocument/rangeFormatting",
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
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        var params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
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
    let labelHook: LSPSymbolLabelHook?

    func documentSymbols(for request: DocumentRequest) async throws -> [DocumentSymbol] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        let result = try await session.requestDictionary(
            "textDocument/documentSymbol",
            params: LSPJSONObject(params)
        )
        guard let arr = result.dictionary["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        var symbols: [DocumentSymbol] = []
        for dict in arr {
            guard let name = dict["name"] as? String else { continue }
            guard let rangeDict = dict["range"] as? [String: Any],
                let selDict = dict["selectionRange"] as? [String: Any],
                let rangeData = try? JSONSerialization.data(withJSONObject: rangeDict),
                let selData = try? JSONSerialization.data(withJSONObject: selDict),
                let range = try? JSONDecoder().decode(LSPRange.self, from: rangeData),
                let sel = try? JSONDecoder().decode(LSPRange.self, from: selData)
            else { continue }
            let detail = dict["detail"] as? String
            var finalName = name
            var finalDetail = detail
            if let labelHook {
                let t = await labelHook(name, detail, nil)
                finalName = t.0
                finalDetail = t.1
            }
            symbols.append(
                DocumentSymbol(
                    name: finalName,
                    detail: finalDetail,
                    kind: .function,
                    range: LSPConvert.textRange(range, in: text),
                    selectionRange: LSPConvert.textRange(sel, in: text)
                ))
        }
        return symbols
    }
}

struct LSPWorkspaceSymbolAdapter: WorkspaceSymbolProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int
    let labelHook: LSPSymbolLabelHook?

    func workspaceSymbols(
        query: String,
        context: LanguageServiceContext
    ) async throws -> [WorkspaceSymbol] {
        _ = context
        let result = try await session.requestDictionary(
            "workspace/symbol",
            params: LSPJSONObject(["query": query])
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        var symbols: [WorkspaceSymbol] = []
        for dict in arr {
            guard let name = dict["name"] as? String,
                let loc = dict["location"] as? [String: Any],
                let uri = loc["uri"] as? String,
                let range = LSPRequestHelpers.parseLSPRange(loc["range"])
            else { continue }
            let container = dict["containerName"] as? String
            var finalName = name
            var finalContainer = container
            if let labelHook {
                let t = await labelHook(name, nil, container)
                finalName = t.0
                finalContainer = t.2
            }
            let documentURI = DocumentURI(rawValue: uri)
            // LSP-N09: fail closed — never invent ranges from empty soft-fallback text.
            let text = try await session.requireText(for: documentURI)
            symbols.append(
                WorkspaceSymbol(
                    name: finalName,
                    kind: .function,
                    location: Location(
                        uri: documentURI,
                        range: LSPConvert.textRange(range, in: text)
                    ),
                    containerName: finalContainer
                ))
        }
        return symbols
    }
}

struct LSPSemanticTokensAdapter: SemanticTokensProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int
    let supportsRange: Bool

    func semanticTokens(for request: DocumentRequest) async throws -> [SemanticTokenSpan] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        guard
            let tokens: LSPSemanticTokens = try await session.requestOptionalJSON(
                "textDocument/semanticTokens/full",
                params: LSPJSONObject(params)
            )
        else {
            return []
        }
        return decodeSemanticTokens(tokens.data, text: request.document.text)
    }

    func semanticTokens(for request: RangeRequest) async throws -> [SemanticTokenSpan] {
        if supportsRange {
            let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
            let params = LSPRequestHelpers.rangeParams(
                uri: request.context.uri,
                range: request.range,
                text: request.document.text,
                map: map
            )
            if let tokens: LSPSemanticTokens = try await session.requestOptionalJSON(
                "textDocument/semanticTokens/range",
                params: LSPJSONObject(params)
            ) {
                return decodeSemanticTokens(tokens.data, text: request.document.text)
            }
        }
        let all = try await semanticTokens(
            for: DocumentRequest(document: request.document, context: request.context)
        )
        return all.filter {
            // DOC-N05: overflow-safe intersection (no location+length).
            LanguageServiceSanitize.rangesIntersect($0.range, request.range)
        }
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

struct LSPCodeActionAdapter: CodeActionProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func codeActions(
        for request: RangeRequest,
        diagnostics: [LanguageDiagnostic]
    ) async throws -> [CodeAction] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        var params = LSPRequestHelpers.rangeParams(
            uri: request.context.uri,
            range: request.range,
            text: request.document.text,
            map: map
        )
        params["context"] = [
            "diagnostics": diagnostics.map { d -> [String: Any] in
                let r = LSPConvert.range(d.range, in: request.document.text)
                return [
                    "range": [
                        "start": ["line": r.start.line, "character": r.start.character],
                        "end": ["line": r.end.line, "character": r.end.character],
                    ],
                    "message": d.message,
                    "severity": 2,
                ]
            }
        ]
        let result = try await session.requestDictionary(
            "textDocument/codeAction",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> CodeAction? in
            guard let title = dict["title"] as? String else { return nil }
            return CodeAction(
                title: title,
                kind: dict["kind"] as? String,
                commandID: (dict["command"] as? [String: Any])?["command"] as? String,
                isPreferred: dict["isPreferred"] as? Bool ?? false
            )
        }
    }
}

struct LSPSignatureHelpAdapter: SignatureHelpProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func signatureHelp(for request: PositionRequest) async throws -> SignatureHelp? {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(
            "textDocument/signatureHelp",
            params: LSPJSONObject(params)
        )
        guard let sigs = result["signatures"] as? [[String: Any]] else { return nil }
        let signatures = sigs.compactMap { dict -> SignatureInformation? in
            guard let label = dict["label"] as? String else { return nil }
            let params = (dict["parameters"] as? [[String: Any]] ?? []).compactMap { p -> ParameterInformation? in
                guard let l = p["label"] as? String else { return nil }
                return ParameterInformation(label: l)
            }
            return SignatureInformation(label: label, parameters: params)
        }
        return SignatureHelp(
            signatures: signatures,
            activeSignature: result["activeSignature"] as? Int ?? 0,
            activeParameter: result["activeParameter"] as? Int ?? 0
        )
    }
}

struct LSPInlayHintAdapter: InlayHintProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func inlayHints(for request: RangeRequest) async throws -> [InlayHint] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.rangeParams(
            uri: request.context.uri,
            range: request.range,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(
            "textDocument/inlayHint",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> InlayHint? in
            guard let posDict = dict["position"] as? [String: Any],
                let line = posDict["line"] as? Int ?? (posDict["line"] as? NSNumber)?.intValue,
                let character = posDict["character"] as? Int ?? (posDict["character"] as? NSNumber)?.intValue
            else { return nil }
            let label: String
            if let s = dict["label"] as? String {
                label = s
            } else if let parts = dict["label"] as? [[String: Any]] {
                label = parts.compactMap { $0["value"] as? String }.joined()
            } else {
                return nil
            }
            let kind: InlayHintKind?
            switch dict["kind"] as? Int {
            case 1: kind = .type
            case 2: kind = .parameter
            default: kind = .other
            }
            return InlayHint(
                position: LSPConvert.textPosition(LSPPosition(line: line, character: character), in: text),
                label: label,
                kind: kind
            )
        }
    }
}

struct LSPFoldingRangeAdapter: FoldingRangeProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func foldingRanges(for request: DocumentRequest) async throws -> [FoldingRange] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        let result = try await session.requestDictionary(
            "textDocument/foldingRange",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> FoldingRange? in
            guard let start = dict["startLine"] as? Int ?? (dict["startLine"] as? NSNumber)?.intValue,
                let end = dict["endLine"] as? Int ?? (dict["endLine"] as? NSNumber)?.intValue
            else { return nil }
            return FoldingRange(
                startLine: start,
                endLine: end,
                startCharacter: dict["startCharacter"] as? Int,
                endCharacter: dict["endCharacter"] as? Int,
                kind: dict["kind"] as? String
            )
        }
    }
}

struct LSPDocumentLinkAdapter: DocumentLinkProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func documentLinks(for request: DocumentRequest) async throws -> [DocumentLink] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        let result = try await session.requestDictionary(
            "textDocument/documentLink",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> DocumentLink? in
            guard let range = LSPRequestHelpers.parseLSPRange(dict["range"]) else { return nil }
            let target = (dict["target"] as? String).map { DocumentURI(rawValue: $0) }
            return DocumentLink(range: LSPConvert.textRange(range, in: text), target: target)
        }
    }
}

struct LSPDocumentColorAdapter: DocumentColorProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func documentColors(for request: DocumentRequest) async throws -> [ColorInformation] {
        let params: [String: Any] = [
            "textDocument": ["uri": request.context.uri?.rawValue ?? ""]
        ]
        let result = try await session.requestDictionary(
            "textDocument/documentColor",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> ColorInformation? in
            guard let range = LSPRequestHelpers.parseLSPRange(dict["range"]),
                let color = dict["color"] as? [String: Any],
                let r = color["red"] as? Double,
                let g = color["green"] as? Double,
                let b = color["blue"] as? Double
            else { return nil }
            let a = color["alpha"] as? Double ?? 1
            return ColorInformation(
                range: LSPConvert.textRange(range, in: text),
                color: ColorValue(red: r, green: g, blue: b, alpha: a)
            )
        }
    }
}

struct LSPDocumentHighlightAdapter: DocumentHighlightProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func documentHighlights(for request: PositionRequest) async throws -> [DocumentHighlight] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(
            "textDocument/documentHighlight",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> DocumentHighlight? in
            guard let range = LSPRequestHelpers.parseLSPRange(dict["range"]) else { return nil }
            let kind: DocumentHighlightKind
            switch dict["kind"] as? Int {
            case 2: kind = .read
            case 3: kind = .write
            default: kind = .text
            }
            return DocumentHighlight(range: LSPConvert.textRange(range, in: text), kind: kind)
        }
    }
}

struct LSPTypeHierarchyAdapter: TypeHierarchyProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func prepareTypeHierarchy(for request: PositionRequest) async throws -> [HierarchyItem] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(
            "textDocument/prepareTypeHierarchy",
            params: LSPJSONObject(params)
        )
        return parseHierarchy(result, text: request.document.text)
    }

    private func parseHierarchy(_ result: LSPJSONObject, text: String) -> [HierarchyItem] {
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> HierarchyItem? in
            guard let name = dict["name"] as? String,
                let uri = dict["uri"] as? String,
                let range = LSPRequestHelpers.parseLSPRange(dict["range"]),
                let sel = LSPRequestHelpers.parseLSPRange(dict["selectionRange"])
            else { return nil }
            return HierarchyItem(
                name: name,
                kind: .class,
                detail: dict["detail"] as? String,
                uri: DocumentURI(rawValue: uri),
                range: LSPConvert.textRange(range, in: text),
                selectionRange: LSPConvert.textRange(sel, in: text)
            )
        }
    }
}

struct LSPCallHierarchyAdapter: CallHierarchyProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int

    func prepareCallHierarchy(for request: PositionRequest) async throws -> [CallHierarchyItem] {
        let map = await session.positionMap(uri: request.context.uri ?? DocumentURI(rawValue: ""))
        let params = LSPRequestHelpers.positionParams(
            uri: request.context.uri,
            position: request.position,
            text: request.document.text,
            map: map
        )
        let result = try await session.requestDictionary(
            "textDocument/prepareCallHierarchy",
            params: LSPJSONObject(params)
        )
        guard let arr = result["_value"] as? [[String: Any]] else { return [] }
        let text = request.document.text
        return arr.compactMap { dict -> CallHierarchyItem? in
            guard let name = dict["name"] as? String,
                let uri = dict["uri"] as? String,
                let range = LSPRequestHelpers.parseLSPRange(dict["range"]),
                let sel = LSPRequestHelpers.parseLSPRange(dict["selectionRange"])
            else { return nil }
            return CallHierarchyItem(
                name: name,
                kind: .function,
                detail: dict["detail"] as? String,
                uri: DocumentURI(rawValue: uri),
                range: LSPConvert.textRange(range, in: text),
                selectionRange: LSPConvert.textRange(sel, in: text)
            )
        }
    }
}

struct LSPExecuteCommandAdapter: ExecuteCommandProvider {
    let session: LanguageServerSession
    let id: ProviderID
    let selector: DocumentSelector
    let priority: Int
    let commands: Set<String>

    var supportedCommands: Set<String> { commands }

    func execute(_ request: ExecuteCommandRequest) async throws -> ExecuteCommandResult {
        var params: [String: Any] = ["command": request.command]
        if let json = request.argumentsJSON,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
        {
            params["arguments"] = obj
        }
        _ = try await session.requestDictionary(
            "workspace/executeCommand",
            params: LSPJSONObject(params)
        )
        return ExecuteCommandResult(message: "executed")
    }
}
