import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorWorkspace
import Foundation

/// Dynamic capability registration record (LSP-N10).
public struct LSPDynamicRegistrationRecord: Sendable, Hashable {
    public var id: String
    public var method: String
    public var registerOptions: LSPJSONObject?

    public init(id: String, method: String, registerOptions: LSPJSONObject? = nil) {
        self.id = id
        self.method = method
        self.registerOptions = registerOptions
    }

    public static func == (lhs: LSPDynamicRegistrationRecord, rhs: LSPDynamicRegistrationRecord) -> Bool {
        lhs.id == rhs.id && lhs.method == rhs.method
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(method)
    }
}

/// One running language server connection.
public actor LanguageServerSession {
    public let definition: LanguageServerDefinition
    public private(set) var state: LanguageServerState = .idle
    public private(set) var capabilities: ServerCapabilitiesSnapshot = .empty

    private let log: LSPLog
    private var connection: LSPJSONRPCConnection?
    private var transport: (any LSPTransport)?
    private var openDocuments: [DocumentURI: LSPOpenDocumentState] = [:]
    private var openPhases: [DocumentURI: LSPDocumentOpenPhase] = [:]
    private var makeTransport: (@Sendable () async throws -> any LSPTransport)?

    // Diagnostics push
    private var diagnosticsContinuation: AsyncStream<LSPDiagnosticsEvent>.Continuation?
    public let diagnosticsStream: AsyncStream<LSPDiagnosticsEvent>

    // Progress
    private var progressContinuation: AsyncStream<LSPJSONRPCConnection.ProgressEvent>.Continuation?
    public let progressStream: AsyncStream<LSPJSONRPCConnection.ProgressEvent>

    public let budgets: LSPServerBudgets
    public let positionMaps = LSPPositionMapCache()
    /// Cross-file URI → text resolver (LSP-N09).
    public let snapshotResolver: LSPSnapshotResolverBox
    public private(set) var restartAttempts: Int = 0
    /// Registration ID → full record (LSP-N10).
    private var dynamicRegistrations: [String: LSPDynamicRegistrationRecord] = [:]
    /// Methods enabled via any active dynamic registration (derived).
    public private(set) var dynamicallyEnabledMethods: Set<String> = []
    /// Negotiated position encoding. Default UTF-16.
    public private(set) var negotiatedPositionEncoding: String = "utf-16"
    /// Versioned diagnostics store (LSP-N12).
    public let diagnosticStore = LSPDiagnosticStore()
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
        transportFactory: (@Sendable () async throws -> any LSPTransport)? = nil,
        snapshotResolver: LSPSnapshotResolverBox? = nil
    ) {
        self.definition = definition
        self.log = log
        self.budgets = budgets
        self.makeTransport = transportFactory
        self.snapshotResolver =
            snapshotResolver
            ?? LSPSnapshotResolverBox(
                DefaultWorkspaceSnapshotResolver(openDocumentText: { _ in nil })
            )
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

    public func documentOpenPhase(uri: DocumentURI) -> LSPDocumentOpenPhase {
        openPhases[uri] ?? .closed
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
            if let enc = initResult.dictionary["positionEncoding"] as? String {
                negotiatedPositionEncoding = enc
            } else if let caps = initResult.dictionary["capabilities"] as? [String: Any],
                let enc = caps["positionEncoding"] as? String
            {
                negotiatedPositionEncoding = enc
            } else {
                negotiatedPositionEncoding = "utf-16"
            }
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
        openPhases.removeAll()
        await diagnosticStore.clearServer(definition.id.rawValue)
        dynamicallyEnabledMethods.removeAll()
        dynamicRegistrations.removeAll()
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

    /// Whether a method was dynamically registered (LSP-N10).
    public func isDynamicallyEnabled(_ method: String) -> Bool {
        dynamicallyEnabledMethods.contains(method)
    }

    public func dynamicRegistrationIDs() -> [String] {
        Array(dynamicRegistrations.keys).sorted()
    }

    public func dynamicRegistration(id: String) -> LSPDynamicRegistrationRecord? {
        dynamicRegistrations[id]
    }

    /// Test/host helper: apply registerCapability payload (LSP-N10).
    public func applyDynamicRegistrations(_ regs: [[String: Any]]) throws {
        for reg in regs {
            guard let id = reg["id"] as? String, let method = reg["method"] as? String else {
                throw LSPError.decode("registration missing id/method")
            }
            let options: LSPJSONObject?
            if let opts = reg["registerOptions"] as? [String: Any] {
                options = LSPJSONObject(opts)
            } else {
                options = nil
            }
            dynamicRegistrations[id] = LSPDynamicRegistrationRecord(
                id: id,
                method: method,
                registerOptions: options
            )
        }
        rebuildDynamicallyEnabledMethods()
    }

    public func applyDynamicUnregistrations(_ unregs: [[String: Any]]) throws {
        for reg in unregs {
            guard let id = reg["id"] as? String else {
                throw LSPError.decode("unregistration missing id")
            }
            dynamicRegistrations.removeValue(forKey: id)
        }
        rebuildDynamicallyEnabledMethods()
    }

    private func rebuildDynamicallyEnabledMethods() {
        dynamicallyEnabledMethods = Set(dynamicRegistrations.values.map(\.method))
    }

    private func restartBackoffNanoseconds(attempt: Int) -> UInt64 {
        let initial =
            Double(budgets.restartInitialBackoff.components.seconds)
            + Double(budgets.restartInitialBackoff.components.attoseconds) / 1e18
        let maximum =
            Double(budgets.restartMaxBackoff.components.seconds)
            + Double(budgets.restartMaxBackoff.components.attoseconds) / 1e18
        let delay = min(maximum, initial * pow(2.0, Double(attempt)))
        return UInt64(delay * 1_000_000_000)
    }

    public func markFailed() async {
        state = .failed
        await cleanupConnection()
        log.append(level: .error, message: "Server crashed/failed", serverID: definition.id.rawValue)
    }

    // MARK: - Document sync (commit after send — LSP-N07)

    public func didOpen(
        uri: DocumentURI,
        languageID: String,
        version: DocumentVersion,
        text: String
    ) async throws {
        try await sendDidOpen(uri: uri, languageID: languageID, version: version, text: text)
    }

    /// Transport write first; host open state only after success (LSP-N07).
    public func sendDidOpen(
        uri: DocumentURI,
        languageID: String,
        version: DocumentVersion,
        text: String
    ) async throws {
        try requireRunning()
        openPhases[uri] = .opening
        guard let connection else {
            openPhases[uri] = .failed
            throw LSPError.notRunning
        }
        do {
            try await connection.notifyDictionary(
                "textDocument/didOpen",
                params: LSPJSONObject([
                    "textDocument": [
                        "uri": uri.rawValue,
                        "languageId": languageID,
                        "version": Int(version.rawValue),
                        "text": text,
                    ] as [String: Any]
                ])
            )
        } catch {
            openPhases[uri] = .failed
            openDocuments.removeValue(forKey: uri)
            throw error
        }
        openDocuments[uri] = LSPOpenDocumentState(
            uri: uri,
            languageID: languageID,
            version: version,
            text: text
        )
        openPhases[uri] = .open
        _ = await positionMaps.map(for: uri, version: version, text: text)
        await rebindSnapshotResolver()
    }

    /// Safe synchronize: base snapshot + applied transaction + new snapshot (LSP-N03).
    public func synchronize(
        document: DocumentID,
        uri: DocumentURI,
        from old: DocumentSnapshot,
        applying transaction: AppliedEditTransaction,
        to new: DocumentSnapshot
    ) async throws {
        _ = document
        try requireRunning()
        guard openDocuments[uri] != nil, openPhases[uri] == .open else {
            throw LSPError.documentNotOpen(uri: uri.rawValue)
        }
        if transaction.oldVersion != old.version || transaction.newVersion != new.version {
            throw LSPError.invalidSynchronize("transaction/snapshot version mismatch")
        }
        if let doc = openDocuments[uri], doc.version != old.version {
            // Version gap → full text resync.
            try await sendDidChangeFull(uri: uri, version: new.version, text: new.text)
            return
        }

        let useIncremental =
            capabilities.incrementalSync && capabilities.textDocumentSyncKind == .incremental
        if useIncremental {
            var contentChanges: [[String: Any]] = []
            for change in transaction.transaction.changes {
                let start = LSPConvert.lineCharacter(
                    utf16Offset: change.replacedRange.location,
                    in: old.text
                )
                let end = LSPConvert.lineCharacter(
                    utf16Offset: change.replacedRange.endUTF16Offset,
                    in: old.text
                )
                contentChanges.append([
                    "range": [
                        "start": ["line": start.line, "character": start.character],
                        "end": ["line": end.line, "character": end.character],
                    ],
                    "text": change.replacement,
                ] as [String: Any])
            }
            if contentChanges.isEmpty {
                try await sendDidChangeFull(uri: uri, version: new.version, text: new.text)
            } else {
                try await sendDidChangeRaw(
                    uri: uri,
                    version: new.version,
                    contentChanges: contentChanges,
                    fullText: new.text
                )
            }
        } else {
            try await sendDidChangeFull(uri: uri, version: new.version, text: new.text)
        }
    }

    /// Full-text didChange only (no fabricated ranges).
    public func sendDidChangeFull(
        uri: DocumentURI,
        version: DocumentVersion,
        text: String
    ) async throws {
        try await sendDidChangeRaw(
            uri: uri,
            version: version,
            contentChanges: [["text": text]],
            fullText: text
        )
    }

    /// Low-level change notification with already-encoded LSP contentChanges.
    public func didChangeRaw(
        uri: DocumentURI,
        version: DocumentVersion,
        contentChanges: [[String: Any]],
        fullText: String
    ) async throws {
        try await sendDidChangeRaw(
            uri: uri,
            version: version,
            contentChanges: contentChanges,
            fullText: fullText
        )
    }

    public func sendDidChangeRaw(
        uri: DocumentURI,
        version: DocumentVersion,
        contentChanges: [[String: Any]],
        fullText: String
    ) async throws {
        try requireRunning()
        guard let connection else { throw LSPError.notRunning }
        try await connection.notifyDictionary(
            "textDocument/didChange",
            params: LSPJSONObject([
                "textDocument": [
                    "uri": uri.rawValue,
                    "version": Int(version.rawValue),
                ] as [String: Any],
                "contentChanges": contentChanges,
            ])
        )
        // Commit local state only after successful send (LSP-N07).
        if var doc = openDocuments[uri] {
            doc.version = version
            doc.text = fullText
            openDocuments[uri] = doc
        }
        _ = await positionMaps.map(for: uri, version: version, text: fullText)
        await rebindSnapshotResolver()
    }

    public func didSave(uri: DocumentURI, text: String?) async throws {
        try await sendDidSave(uri: uri, text: text)
    }

    public func sendDidSave(uri: DocumentURI, text: String?) async throws {
        try requireRunning()
        guard let connection else { throw LSPError.notRunning }
        var params: [String: Any] = [
            "textDocument": ["uri": uri.rawValue]
        ]
        if let text {
            params["text"] = text
        }
        try await connection.notifyDictionary("textDocument/didSave", params: LSPJSONObject(params))
    }

    public func didClose(uri: DocumentURI) async throws {
        try await sendDidClose(uri: uri)
    }

    public func sendDidClose(uri: DocumentURI) async throws {
        try requireRunning()
        openPhases[uri] = .closing
        guard let connection else {
            openPhases[uri] = .failed
            throw LSPError.notRunning
        }
        do {
            try await connection.notifyDictionary(
                "textDocument/didClose",
                params: LSPJSONObject([
                    "textDocument": ["uri": uri.rawValue]
                ])
            )
        } catch {
            openPhases[uri] = .failed
            throw error
        }
        openDocuments.removeValue(forKey: uri)
        openPhases[uri] = .closed
        await positionMaps.invalidate(uri: uri)
        await rebindSnapshotResolver()
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

    public func requestJSONValue(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> JSONValue {
        try requireRunning()
        guard let connection else { throw LSPError.notRunning }
        return try await connection.requestJSONValue(method, params: params)
    }

    public func requestJSON<R: Decodable>(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> R {
        let obj = try await requestDictionary(method, params: params)
        if let value = obj["_value"] {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed]
            )
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

    // MARK: - Snapshots (LSP-N09)

    /// Text for URI: open document first, else snapshot resolver.
    /// Throws ``LSPError/snapshotUnavailable`` — never fabricates empty text (LSP-N09).
    public func requireText(for uri: DocumentURI) async throws -> String {
        if let doc = openDocuments[uri] { return doc.text }
        let snap = try await snapshotResolver.snapshot(for: uri)
        return snap.text
    }

    public func positionMap(uri: DocumentURI) async -> LSPPositionMap? {
        guard let doc = openDocuments[uri] else { return nil }
        return await positionMaps.map(for: uri, version: doc.version, text: doc.text)
    }

    public func refreshSnapshotResolver() async {
        await rebindSnapshotResolver()
    }

    private func rebindSnapshotResolver() async {
        let open = openDocuments
        await snapshotResolver.set(
            DefaultWorkspaceSnapshotResolver(openDocumentText: { uri in
                if let doc = open[uri] {
                    return (doc.text, doc.version)
                }
                return nil
            })
        )
    }

    // MARK: - WorkspaceEdit (LSP-N08)

    public func decodeWorkspaceEdit(_ dict: [String: Any]) async throws -> WorkspaceEditPlan {
        try await parseWorkspaceEdit(dict)
    }

    public func workspaceEdit(from plan: WorkspaceEditPlan) async throws -> WorkspaceEdit {
        var documentChanges: [DocumentChange] = []
        for doc in plan.documentEdits {
            let edits = doc.edits.map { edit in
                TextChange(replacedRange: edit.range, replacement: edit.newText)
            }
            documentChanges.append(
                DocumentChange(
                    uri: doc.uri,
                    expectedVersion: nil,
                    transaction: EditTransaction(changes: edits, origin: .programmatic)
                )
            )
        }
        for vdoc in plan.versionedDocumentEdits {
            let edits = vdoc.edits.map { edit in
                TextChange(replacedRange: edit.range, replacement: edit.newText)
            }
            let expected: DocumentVersion? =
                vdoc.version.map { DocumentVersion(rawValue: UInt64(max(0, $0))) }
            documentChanges.append(
                DocumentChange(
                    uri: vdoc.uri,
                    expectedVersion: expected,
                    transaction: EditTransaction(changes: edits, origin: .programmatic)
                )
            )
        }
        var fileOps: [WorkspaceFileOperation] = []
        for op in plan.resourceOperations {
            switch op {
            case .create(let uri, _):
                fileOps.append(.createFile(uri: uri, contents: ""))
            case .rename(let from, let to, _):
                fileOps.append(.rename(from: from, to: to))
            case .delete(let uri, _):
                fileOps.append(.delete(uri: uri))
            }
        }
        // Annotations requiring confirmation are host policy; fail closed if any need confirmation
        // and no host has pre-approved (caller checks plan.changeAnnotations).
        return WorkspaceEdit(documentChanges: documentChanges, fileOperations: fileOps)
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
                    "positionEncodings": ["utf-16"]
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
                        "completionItem": [
                            "snippetSupport": false, "documentationFormat": ["markdown", "plaintext"],
                        ],
                        "contextSupport": true,
                    ],
                    "hover": [
                        "contentFormat": ["markdown", "plaintext"], "dynamicRegistration": true,
                    ],
                    "definition": ["linkSupport": true, "dynamicRegistration": true],
                    "declaration": ["linkSupport": true, "dynamicRegistration": true],
                    "implementation": ["linkSupport": true, "dynamicRegistration": true],
                    "references": ["dynamicRegistration": true],
                    "documentHighlight": ["dynamicRegistration": true],
                    "documentSymbol": [
                        "hierarchicalDocumentSymbolSupport": true, "dynamicRegistration": true,
                    ],
                    "codeAction": [
                        "dynamicRegistration": true, "resolveSupport": ["properties": ["edit", "command"]],
                    ],
                    "formatting": ["dynamicRegistration": true],
                    "rangeFormatting": ["dynamicRegistration": true],
                    "rename": ["dynamicRegistration": true, "prepareSupport": false],
                    "publishDiagnostics": ["relatedInformation": false, "versionSupport": true],
                    "diagnostic": ["dynamicRegistration": true],
                    "signatureHelp": ["dynamicRegistration": true],
                    "documentLink": ["dynamicRegistration": true],
                    "colorProvider": ["dynamicRegistration": true],
                    "foldingRange": ["dynamicRegistration": true],
                    "inlayHint": [
                        "dynamicRegistration": true,
                        "resolveSupport": ["properties": ["tooltip", "textEdits"]],
                    ],
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
                    "workspaceEdit": [
                        "documentChanges": true,
                        "resourceOperations": ["create", "rename", "delete"],
                        "failureHandling": "abort",
                        "changeAnnotationSupport": ["groupsOnLabel": true],
                    ],
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
                let gen = await diagnosticStore.serverGeneration(for: definition.id.rawValue)
                let stored = params.diagnostics.enumerated().map { idx, d in
                    LSPStoredDiagnostic(
                        id: "\(uri.rawValue):\(idx):\(d.range.start.line):\(d.range.start.character)",
                        message: d.message,
                        severity: d.severity ?? 1,
                        line: d.range.start.line,
                        character: d.range.start.character,
                        endLine: d.range.end.line,
                        endCharacter: d.range.end.character,
                        source: d.source
                    )
                }
                await diagnosticStore.publish(
                    serverID: definition.id.rawValue,
                    serverGeneration: gen,
                    uri: uri,
                    version: params.version,
                    items: stored,
                    source: params.diagnostics.first?.source ?? definition.id.rawValue
                )
                diagnosticsContinuation?.yield(
                    LSPDiagnosticsEvent(
                        uri: uri,
                        version: params.version.map { DocumentVersion(rawValue: UInt64(max(0, $0))) },
                        diagnostics: diags
                    )
                )
            }
        case "window/logMessage", "window/showMessage":
            if let obj = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any],
                let message = obj["message"] as? String
            {
                log.append(level: .info, message: message, serverID: definition.id.rawValue)
            }
        case "$/progress":
            break
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
            do {
                let plan = try await parseWorkspaceEdit(editDict)
                if let handler = applyEditHandler {
                    let applied = await handler(plan)
                    return LSPAnyJSON(["applied": applied])
                }
                return LSPAnyJSON(["applied": false, "failureReason": "no applyEdit handler"])
            } catch {
                // Fail closed on snapshot miss — do not apply with empty text (LSP-N09).
                return LSPAnyJSON([
                    "applied": false,
                    "failureReason": String(describing: error),
                ])
            }
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
            return LSPAnyJSON(
                definition.workspaceRootURIs.map {
                    ["uri": $0.rawValue, "name": $0.rawValue] as [String: Any]
                })
        case "client/registerCapability":
            if let registrations = params["registrations"] as? [[String: Any]] {
                try applyDynamicRegistrations(registrations)
            }
            return .null
        case "client/unregisterCapability":
            if let unregs = params["unregisterations"] as? [[String: Any]]
                ?? params["unregistrations"] as? [[String: Any]]
            {
                try applyDynamicUnregistrations(unregs)
            }
            return .null
        case "window/workDoneProgress/create":
            return .null
        default:
            throw LSPError.serverError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func parseWorkspaceEdit(_ dict: [String: Any]) async throws -> WorkspaceEditPlan {
        var docs: [DocumentEditPlan] = []
        var versioned: [VersionedDocumentEditPlan] = []
        var resources: [WorkspaceResourceOperation] = []
        var annotations: [String: WorkspaceChangeAnnotation] = [:]

        if let changes = dict["changes"] as? [String: [[String: Any]]] {
            for (uri, edits) in changes {
                let documentURI = DocumentURI(rawValue: uri)
                let text = try await requireText(for: documentURI)
                if let data = try? JSONSerialization.data(withJSONObject: edits),
                    let decoded = try? JSONDecoder().decode([LSPTextEdit].self, from: data)
                {
                    docs.append(
                        DocumentEditPlan(
                            uri: documentURI,
                            edits: decoded.map { LSPConvert.textEditPlan($0, in: text) }
                        )
                    )
                }
            }
        }

        if let documentChanges = dict["documentChanges"] as? [Any] {
            for entry in documentChanges {
                guard let item = entry as? [String: Any] else { continue }
                if let kind = item["kind"] as? String {
                    switch kind {
                    case "create":
                        if let uri = item["uri"] as? String {
                            let overwrite = (item["options"] as? [String: Any])?["overwrite"] as? Bool
                            resources.append(.create(uri: DocumentURI(rawValue: uri), overwrite: overwrite))
                        }
                    case "rename":
                        if let old = item["oldUri"] as? String, let new = item["newUri"] as? String {
                            let overwrite = (item["options"] as? [String: Any])?["overwrite"] as? Bool
                            resources.append(
                                .rename(
                                    from: DocumentURI(rawValue: old),
                                    to: DocumentURI(rawValue: new),
                                    overwrite: overwrite
                                )
                            )
                        }
                    case "delete":
                        if let uri = item["uri"] as? String {
                            let recursive = (item["options"] as? [String: Any])?["recursive"] as? Bool
                            resources.append(.delete(uri: DocumentURI(rawValue: uri), recursive: recursive))
                        }
                    default:
                        break
                    }
                    continue
                }
                // TextDocumentEdit
                if let td = item["textDocument"] as? [String: Any],
                    let uri = td["uri"] as? String,
                    let edits = item["edits"] as? [[String: Any]]
                {
                    let documentURI = DocumentURI(rawValue: uri)
                    let version = td["version"] as? Int ?? (td["version"] as? NSNumber)?.intValue
                    let text = try await requireText(for: documentURI)
                    if let data = try? JSONSerialization.data(withJSONObject: edits),
                        let decoded = try? JSONDecoder().decode([LSPTextEdit].self, from: data)
                    {
                        versioned.append(
                            VersionedDocumentEditPlan(
                                uri: documentURI,
                                version: version,
                                edits: decoded.map { LSPConvert.textEditPlan($0, in: text) }
                            )
                        )
                    }
                }
            }
        }

        if let anns = dict["changeAnnotations"] as? [String: [String: Any]] {
            for (id, ann) in anns {
                let label = ann["label"] as? String ?? id
                let needs = ann["needsConfirmation"] as? Bool ?? false
                let description = ann["description"] as? String
                annotations[id] = WorkspaceChangeAnnotation(
                    label: label,
                    needsConfirmation: needs,
                    description: description
                )
            }
        }

        return WorkspaceEditPlan(
            documentEdits: docs,
            versionedDocumentEdits: versioned,
            resourceOperations: resources,
            changeAnnotations: annotations
        )
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
