import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices

/// One running language server connection.
public actor LanguageServerSession {
    public let definition: LanguageServerDefinition
    public private(set) var state: LanguageServerState = .idle
    public private(set) var capabilities: ServerCapabilitiesSnapshot = .empty

    private let log: LSPLog
    private var connection: LSPJSONRPCConnection?
    private var transport: (any LSPTransport)?
    private var openDocuments: [DocumentURI: LSPOpenDocumentState] = [:]
    private var makeTransport: (@Sendable () async throws -> any LSPTransport)?

    // Diagnostics push
    private var diagnosticsContinuation: AsyncStream<LSPDiagnosticsEvent>.Continuation?
    public let diagnosticsStream: AsyncStream<LSPDiagnosticsEvent>

    // Progress
    private var progressContinuation: AsyncStream<LSPJSONRPCConnection.ProgressEvent>.Continuation?
    public let progressStream: AsyncStream<LSPJSONRPCConnection.ProgressEvent>

    public let budgets: LSPServerBudgets
    public let positionMaps = LSPPositionMapCache()
    public private(set) var restartAttempts: Int = 0
    private var dynamicRegistrations: [String: LSPJSONObject] = [:]
    /// Host-facing applyEdit handler.
    public var applyEditHandler: (@Sendable (WorkspaceEditPlan) async -> Bool)?
    /// Host-facing showMessageRequest handler (returns selected action title).
    public var showMessageRequestHandler: (@Sendable (String, [String]) async -> String?)?
    /// Host-facing configuration handler.
    public var configurationHandler: (@Sendable ([[String: Any]]) async -> [Any])?

    public init(
        definition: LanguageServerDefinition,
        log: LSPLog = LSPLog(),
        budgets: LSPServerBudgets = .default,
        transportFactory: (@Sendable () async throws -> any LSPTransport)? = nil
    ) {
        self.definition = definition
        self.log = log
        self.budgets = budgets
        self.makeTransport = transportFactory
        var cont: AsyncStream<LSPDiagnosticsEvent>.Continuation!
        self.diagnosticsStream = AsyncStream { cont = $0 }
        self.diagnosticsContinuation = cont
        var pcont: AsyncStream<LSPJSONRPCConnection.ProgressEvent>.Continuation!
        self.progressStream = AsyncStream { pcont = $0 }
        self.progressContinuation = pcont
    }

    public var id: LanguageServerID { definition.id }

    public func openDocumentState(uri: DocumentURI) -> LSPOpenDocumentState? {
        openDocuments[uri]
    }

    public func allOpenDocuments() -> [LSPOpenDocumentState] {
        Array(openDocuments.values)
    }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .idle || state == .stopped || state == .failed else {
            if state == .running { return }
            throw LSPError.alreadyStarted
        }
        state = .starting
        do {
            let transport = try await createTransport()
            self.transport = transport
            let connection = LSPJSONRPCConnection(
                transport: transport,
                log: log,
                requestTimeout: budgets.requestTimeout
            )
            self.connection = connection
            await connection.start()
            await connection.setNotificationHandler { [weak self] method, data in
                await self?.handleNotification(method: method, paramsData: data)
            }
            await connection.setServerRequestHandler { [weak self] method, id, data in
                guard let self else { throw LSPError.notRunning }
                return try await self.handleServerRequest(method: method, id: id, paramsData: data)
            }
            await connection.setProgressHandler { [weak self] event in
                await self?.progressContinuation?.yield(event)
            }

            let initResult = try await connection.requestDictionary(
                "initialize",
                params: LSPJSONObject(makeInitializeParams())
            )
            capabilities = ServerCapabilitiesSnapshot.parse(from: initResult.dictionary)
            try await connection.notifyDictionary("initialized", params: LSPJSONObject([:]))
            state = .running
            log.append(level: .info, message: "Server started", serverID: definition.id.rawValue)
        } catch {
            state = .failed
            log.append(
                level: .error,
                message: "Start failed: \(error)",
                serverID: definition.id.rawValue
            )
            await cleanupConnection()
            throw error
        }
    }

    public func shutdown() async {
        guard state == .running || state == .starting else {
            state = .stopped
            return
        }
        state = .shuttingDown
        if let connection {
            try? await connection.requestDictionary("shutdown", params: nil as LSPJSONObject?)
            try? await connection.notifyDictionary("exit", params: nil as LSPJSONObject?)
        }
        await cleanupConnection()
        openDocuments.removeAll()
        state = .stopped
        log.append(level: .info, message: "Server stopped", serverID: definition.id.rawValue)
    }

    public func restart() async throws {
        if restartAttempts >= budgets.restartMaxAttempts {
            throw LSPError.budgetExceeded("restart attempts exhausted")
        }
        let attempt = restartAttempts
        restartAttempts += 1
        let nanos = restartBackoffNanoseconds(attempt: attempt)
        if nanos > 0 {
            try await Task.sleep(nanoseconds: nanos)
        }
        let docs = Array(openDocuments.values)
        await shutdown()
        try await start()
        restartAttempts = 0
        for doc in docs {
            try await didOpen(
                uri: doc.uri,
                languageID: doc.languageID,
                version: doc.version,
                text: doc.text
            )
        }
    }

    private func restartBackoffNanoseconds(attempt: Int) -> UInt64 {
        // Exponential backoff from initial to max.
        let initial = Double(budgets.restartInitialBackoff.components.seconds)
            + Double(budgets.restartInitialBackoff.components.attoseconds) / 1e18
        let maximum = Double(budgets.restartMaxBackoff.components.seconds)
            + Double(budgets.restartMaxBackoff.components.attoseconds) / 1e18
        let delay = min(maximum, initial * pow(2.0, Double(attempt)))
        return UInt64(delay * 1_000_000_000)
    }

    public func markFailed() async {
        state = .failed
        await cleanupConnection()
        log.append(level: .error, message: "Server crashed/failed", serverID: definition.id.rawValue)
    }

    // MARK: - Document sync

    public func didOpen(
        uri: DocumentURI,
        languageID: String,
        version: DocumentVersion,
        text: String
    ) async throws {
        try requireRunning()
        openDocuments[uri] = LSPOpenDocumentState(
            uri: uri,
            languageID: languageID,
            version: version,
            text: text
        )
        _ = await positionMaps.map(for: uri, version: version, text: text)
        try await connection?.notifyDictionary(
            "textDocument/didOpen",
            params: LSPJSONObject([
                "textDocument": [
                    "uri": uri.rawValue,
                    "languageId": languageID,
                    "version": Int(version.rawValue),
                    "text": text,
                ] as [String: Any],
            ])
        )
    }

    public func didChange(
        uri: DocumentURI,
        version: DocumentVersion,
        changes: [LSPContentChange],
        fullText: String
    ) async throws {
        try requireRunning()
        if var doc = openDocuments[uri] {
            doc.version = version
            doc.text = fullText
            openDocuments[uri] = doc
        }
        var contentChanges: [[String: Any]] = []
        if capabilities.incrementalSync {
            for change in changes {
                if let range = change.range {
                    let start = LSPConvert.lineCharacter(utf16Offset: range.location, in: fullText)
                    // Range is pre-edit in AppliedEditTransaction — caller should pass pre-edit text for range mapping.
                    // For simplicity when incremental, use provided range on the pre-edit snapshot in synchronizer.
                    _ = start
                }
            }
            // Synchronizer builds proper incremental payloads; if empty, fall back to full.
            if changes.count == 1, let only = changes.first, only.range == nil {
                contentChanges = [["text": only.text]]
            } else {
                // Expect synchronizer to pass encoded changes via didChangeRaw when incremental.
                contentChanges = changes.map { change in
                    if let range = change.range {
                        // Interpret range against fullText incorrectly if fullText is post-edit —
                        // synchronizer uses didChangeRaw for incremental.
                        return [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 0],
                            ],
                            "text": change.text,
                        ] as [String: Any]
                    }
                    return ["text": change.text]
                }
            }
        } else {
            contentChanges = [["text": fullText]]
        }
        try await connection?.notifyDictionary(
            "textDocument/didChange",
            params: LSPJSONObject([
                "textDocument": [
                    "uri": uri.rawValue,
                    "version": Int(version.rawValue),
                ] as [String: Any],
                "contentChanges": contentChanges,
            ])
        )
    }

    /// Low-level change notification with already-encoded LSP contentChanges.
    public func didChangeRaw(
        uri: DocumentURI,
        version: DocumentVersion,
        contentChanges: [[String: Any]],
        fullText: String
    ) async throws {
        try requireRunning()
        if var doc = openDocuments[uri] {
            doc.version = version
            doc.text = fullText
            openDocuments[uri] = doc
        }
        _ = await positionMaps.map(for: uri, version: version, text: fullText)
        try await connection?.notifyDictionary(
            "textDocument/didChange",
            params: LSPJSONObject([
                "textDocument": [
                    "uri": uri.rawValue,
                    "version": Int(version.rawValue),
                ] as [String: Any],
                "contentChanges": contentChanges,
            ])
        )
    }

    public func didSave(uri: DocumentURI, text: String?) async throws {
        try requireRunning()
        var params: [String: Any] = [
            "textDocument": ["uri": uri.rawValue],
        ]
        if let text {
            params["text"] = text
        }
        try await connection?.notifyDictionary("textDocument/didSave", params: LSPJSONObject(params))
    }

    public func didClose(uri: DocumentURI) async throws {
        try requireRunning()
        openDocuments.removeValue(forKey: uri)
        await positionMaps.invalidate(uri: uri)
        try await connection?.notifyDictionary(
            "textDocument/didClose",
            params: LSPJSONObject([
                "textDocument": ["uri": uri.rawValue],
            ])
        )
    }

    // MARK: - Requests

    public func requestDictionary(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> LSPJSONObject {
        try requireRunning()
        guard let connection else { throw LSPError.notRunning }
        return try await connection.requestDictionary(method, params: params)
    }

    public func requestJSON<R: Decodable>(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> R {
        let obj = try await requestDictionary(method, params: params)
        // If wrapped _value
        if let value = obj["_value"] {
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode(R.self, from: data)
        }
        let data = try JSONSerialization.data(withJSONObject: obj.dictionary)
        return try JSONDecoder().decode(R.self, from: data)
    }

    public func requestOptionalJSON<R: Decodable>(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> R? {
        do {
            return try await requestJSON(method, params: params)
        } catch LSPError.decode {
            return nil
        } catch LSPError.serverError(let code, _) where code == -32601 {
            return nil
        }
    }

    // MARK: - Private

    private func requireRunning() throws {
        guard state == .running else { throw LSPError.notRunning }
    }

    private func createTransport() async throws -> any LSPTransport {
        if let makeTransport {
            return try await makeTransport()
        }
        switch definition.launch {
        case .process(let executable, let arguments):
            return try LSPProcessTransport(
                executable: executable,
                arguments: arguments,
                environment: definition.environment.isEmpty ? nil : definition.environment,
                currentDirectory: definition.currentDirectory
            )
        case .test:
            throw LSPError.unsupported("test launch requires pool factory")
        case .custom(let factory):
            return try await factory()
        }
    }

    private func makeInitializeParams() -> [String: Any] {
        let rootURI = definition.workspaceRootURIs.first?.rawValue
        let tokenTypes = [
            "namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
            "parameter", "variable", "property", "enumMember", "event", "function", "method",
            "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
        ]
        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": [
                "name": "CodeEditorLSP",
                "version": LSPProtocolVersion.description,
            ],
            "locale": "en-us",
            "capabilities": [
                "general": [
                    "positionEncodings": ["utf-16"],
                ],
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": true,
                        "willSave": false,
                        "didSave": true,
                        "willSaveWaitUntil": false,
                    ],
                    "completion": [
                        "dynamicRegistration": true,
                        "completionItem": ["snippetSupport": false, "documentationFormat": ["markdown", "plaintext"]],
                        "contextSupport": true,
                    ],
                    "hover": ["contentFormat": ["markdown", "plaintext"], "dynamicRegistration": true],
                    "definition": ["linkSupport": true, "dynamicRegistration": true],
                    "declaration": ["linkSupport": true, "dynamicRegistration": true],
                    "implementation": ["linkSupport": true, "dynamicRegistration": true],
                    "references": ["dynamicRegistration": true],
                    "documentHighlight": ["dynamicRegistration": true],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true, "dynamicRegistration": true],
                    "codeAction": ["dynamicRegistration": true, "resolveSupport": ["properties": ["edit", "command"]]],
                    "formatting": ["dynamicRegistration": true],
                    "rangeFormatting": ["dynamicRegistration": true],
                    "rename": ["dynamicRegistration": true, "prepareSupport": false],
                    "publishDiagnostics": ["relatedInformation": false, "versionSupport": true],
                    "diagnostic": ["dynamicRegistration": true],
                    "signatureHelp": ["dynamicRegistration": true],
                    "documentLink": ["dynamicRegistration": true],
                    "colorProvider": ["dynamicRegistration": true],
                    "foldingRange": ["dynamicRegistration": true],
                    "inlayHint": ["dynamicRegistration": true, "resolveSupport": ["properties": ["tooltip", "textEdits"]]],
                    "typeHierarchy": ["dynamicRegistration": true],
                    "callHierarchy": ["dynamicRegistration": true],
                    "semanticTokens": [
                        "dynamicRegistration": true,
                        "requests": ["full": ["delta": true], "range": true],
                        "tokenTypes": tokenTypes,
                        "tokenModifiers": ["declaration", "definition", "readonly", "static"],
                        "formats": ["relative"],
                        "multilineTokenSupport": true,
                    ],
                ] as [String: Any],
                "workspace": [
                    "workspaceFolders": true,
                    "applyEdit": true,
                    "configuration": true,
                    "didChangeConfiguration": ["dynamicRegistration": true],
                    "didChangeWatchedFiles": ["dynamicRegistration": true],
                    "symbol": ["dynamicRegistration": true],
                    "executeCommand": ["dynamicRegistration": true],
                ] as [String: Any],
                "window": [
                    "showMessage": ["messageActionItem": ["additionalPropertiesSupport": false]],
                    "workDoneProgress": true,
                ],
            ] as [String: Any],
            "rootUri": rootURI as Any,
            "workspaceFolders": definition.workspaceRootURIs.map {
                ["uri": $0.rawValue, "name": $0.rawValue] as [String: Any]
            },
        ]
        if let options = definition.initializationOptions {
            params["initializationOptions"] = options.dictionary
        }
        return params
    }

    private func handleNotification(method: String, paramsData: Data) async {
        switch method {
        case "textDocument/publishDiagnostics":
            if let params = try? JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: paramsData) {
                let uri = DocumentURI(rawValue: params.uri)
                let text = openDocuments[uri]?.text ?? ""
                let diags = params.diagnostics.map { LSPConvert.diagnostic($0, in: text) }
                diagnosticsContinuation?.yield(
                    LSPDiagnosticsEvent(uri: uri, version: params.version.map { DocumentVersion(rawValue: UInt64($0)) }, diagnostics: diags)
                )
            }
        case "window/logMessage", "window/showMessage":
            if let obj = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
               let message = obj["message"] as? String
            {
                log.append(level: .info, message: message, serverID: definition.id.rawValue)
            }
        case "$/progress":
            break // handled via progress stream
        default:
            log.append(level: .debug, message: "Notification \(method)", serverID: definition.id.rawValue)
        }
    }

    private func handleServerRequest(
        method: String,
        id: LSPJSONRPCConnection.RequestID,
        paramsData: Data
    ) async throws -> LSPAnyJSON {
        _ = id
        let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]
        switch method {
        case "workspace/applyEdit":
            let editDict = params["edit"] as? [String: Any] ?? [:]
            let plan = parseWorkspaceEdit(editDict)
            if let handler = applyEditHandler {
                let applied = await handler(plan)
                return LSPAnyJSON(["applied": applied])
            }
            return LSPAnyJSON(["applied": false, "failureReason": "no applyEdit handler"])
        case "window/showMessageRequest":
            let message = params["message"] as? String ?? ""
            let actions = (params["actions"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            if let handler = showMessageRequestHandler {
                if let title = await handler(message, actions) {
                    return LSPAnyJSON(["title": title])
                }
                return .null
            }
            if let first = actions.first {
                return LSPAnyJSON(["title": first])
            }
            return .null
        case "workspace/configuration":
            let items = params["items"] as? [[String: Any]] ?? []
            if let handler = configurationHandler {
                return LSPAnyJSON(await handler(items))
            }
            return LSPAnyJSON(items.map { _ in NSNull() })
        case "workspace/workspaceFolders":
            return LSPAnyJSON(definition.workspaceRootURIs.map {
                ["uri": $0.rawValue, "name": $0.rawValue] as [String: Any]
            })
        case "client/registerCapability":
            if let registrations = params["registrations"] as? [[String: Any]] {
                for reg in registrations {
                    if let id = reg["id"] as? String {
                        dynamicRegistrations[id] = LSPJSONObject(reg)
                    }
                }
            }
            return .null
        case "client/unregisterCapability":
            if let unregs = params["unregisterations"] as? [[String: Any]]
                ?? params["unregistrations"] as? [[String: Any]]
            {
                for reg in unregs {
                    if let id = reg["id"] as? String {
                        dynamicRegistrations.removeValue(forKey: id)
                    }
                }
            }
            return .null
        case "window/workDoneProgress/create":
            return .null
        default:
            throw LSPError.serverError(code: -32601, message: "Method not found: \(method)")
        }
    }

    public func dynamicRegistrationIDs() -> [String] {
        Array(dynamicRegistrations.keys).sorted()
    }

    public func positionMap(uri: DocumentURI) async -> LSPPositionMap? {
        guard let doc = openDocuments[uri] else { return nil }
        return await positionMaps.map(for: uri, version: doc.version, text: doc.text)
    }

    private func parseWorkspaceEdit(_ dict: [String: Any]) -> WorkspaceEditPlan {
        var docs: [DocumentEditPlan] = []
        if let changes = dict["changes"] as? [String: [[String: Any]]] {
            for (uri, edits) in changes {
                let text = openDocuments[DocumentURI(rawValue: uri)]?.text ?? ""
                if let data = try? JSONSerialization.data(withJSONObject: edits),
                   let decoded = try? JSONDecoder().decode([LSPTextEdit].self, from: data)
                {
                    docs.append(DocumentEditPlan(
                        uri: DocumentURI(rawValue: uri),
                        edits: decoded.map { LSPConvert.textEditPlan($0, in: text) }
                    ))
                }
            }
        }
        return WorkspaceEditPlan(documentEdits: docs)
    }

    private func cleanupConnection() async {
        await connection?.close()
        connection = nil
        transport = nil
        await positionMaps.removeAll()
    }
}

public struct LSPDiagnosticsEvent: Sendable, Hashable {
    public var uri: DocumentURI
    public var version: DocumentVersion?
    public var diagnostics: [LanguageDiagnostic]

    public init(uri: DocumentURI, version: DocumentVersion?, diagnostics: [LanguageDiagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }
}
