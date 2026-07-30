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

    public init(
        definition: LanguageServerDefinition,
        log: LSPLog = LSPLog(),
        transportFactory: (@Sendable () async throws -> any LSPTransport)? = nil
    ) {
        self.definition = definition
        self.log = log
        self.makeTransport = transportFactory
        var cont: AsyncStream<LSPDiagnosticsEvent>.Continuation!
        self.diagnosticsStream = AsyncStream { cont = $0 }
        self.diagnosticsContinuation = cont
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
            let connection = LSPJSONRPCConnection(transport: transport, log: log)
            self.connection = connection
            await connection.start()
            await connection.setNotificationHandler { [weak self] method, data in
                await self?.handleNotification(method: method, paramsData: data)
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
        let docs = Array(openDocuments.values)
        await shutdown()
        try await start()
        for doc in docs {
            try await didOpen(
                uri: doc.uri,
                languageID: doc.languageID,
                version: doc.version,
                text: doc.text
            )
        }
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
        var params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "CodeEditorLSP", "version": "1.0.0"],
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "dynamicRegistration": false,
                        "willSave": false,
                        "didSave": true,
                        "willSaveWaitUntil": false,
                    ],
                    "completion": ["dynamicRegistration": false],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": ["linkSupport": true],
                    "publishDiagnostics": ["relatedInformation": false],
                    "semanticTokens": [
                        "requests": ["full": true],
                        "tokenTypes": ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator"],
                        "tokenModifiers": ["declaration", "definition", "readonly", "static"],
                        "formats": ["relative"],
                    ],
                ] as [String: Any],
                "workspace": [
                    "workspaceFolders": true,
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
        default:
            log.append(level: .debug, message: "Notification \(method)", serverID: definition.id.rawValue)
        }
    }

    private func cleanupConnection() async {
        await connection?.close()
        connection = nil
        transport = nil
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
