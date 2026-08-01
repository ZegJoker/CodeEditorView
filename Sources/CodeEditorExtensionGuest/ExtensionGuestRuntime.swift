import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import Foundation

/// Stdio-backed guest runtime: handshake then serve requests for a ``CodeEditorExtension``.
public actor ExtensionGuestRuntime {
    public let ext: any CodeEditorExtension
    private let transport: any ExtensionWireTransport
    private var connection: ExtensionWireConnection?
    private var activated = false
    private var generation: UInt64 = 0
    private var grantedPermissions: Set<ExtensionPermission> = []
    public var completionHandler: (@Sendable (Data) async throws -> Data)?
    public var hoverHandler: (@Sendable (Data) async throws -> Data)?
    public var definitionHandler: (@Sendable (Data) async throws -> Data)?
    /// Procedural providers (Phase 12–13). Unset → methodNotFound (no canned responses).
    public var languageServerProvider: (any LanguageServerProvider)?
    public var debugAdapterProvider: (any DebugAdapterProvider)?
    public var debugLocatorProvider: (any DebugLocatorProvider)?
    public var mcpServerProvider: (any MCPServerProvider)?
    public var slashCommandProvider: (any SlashCommandProvider)?
    public var documentationIndexProvider: (any DocumentationIndexProvider)?
    public var childPID: Int32?

    public func setLanguageServerProvider(_ provider: (any LanguageServerProvider)?) {
        languageServerProvider = provider
    }

    public func setDebugAdapterProvider(_ provider: (any DebugAdapterProvider)?) {
        debugAdapterProvider = provider
    }

    public func setDebugLocatorProvider(_ provider: (any DebugLocatorProvider)?) {
        debugLocatorProvider = provider
    }

    public func setMCPServerProvider(_ provider: (any MCPServerProvider)?) {
        mcpServerProvider = provider
    }

    public func setSlashCommandProvider(_ provider: (any SlashCommandProvider)?) {
        slashCommandProvider = provider
    }

    public func setDocumentationIndexProvider(_ provider: (any DocumentationIndexProvider)?) {
        documentationIndexProvider = provider
    }

    private let log: ExtensionLog
    private var context: GuestExtensionContext?

    public init(
        extension ext: any CodeEditorExtension,
        transport: any ExtensionWireTransport,
        log: ExtensionLog = ExtensionLog()
    ) {
        self.ext = ext
        self.transport = transport
        self.log = log
    }

    public func run() async {
        let connection = ExtensionWireConnection(transport: transport)
        self.connection = connection
        await connection.start()
        await connection.setEnvelopeHandler { [weak self] envelope in
            await self?.handle(envelope)
        }
        let handshake = ExtensionWireHandshake(
            manifest: ext.manifest,
            runtimeKind: "native-process"
        )
        try? await connection.send(.handshake(handshake))
    }

    public func stop() async {
        if activated {
            await ext.deactivate()
            activated = false
        }
        context?.teardown()
        context = nil
        await connection?.close()
        connection = nil
        if let pid = childPID, pid > 0 {
            kill(pid, SIGTERM)
            kill(pid, SIGKILL)
            childPID = nil
        }
    }

    private func handle(_ envelope: ExtensionEnvelope) async {
        switch envelope {
        case .handshakeResult(let result):
            if !result.accepted {
                await connection?.close()
                return
            }
            generation = result.generation
            await connection?.setGeneration(result.generation)
            grantedPermissions = Set(result.grantedPermissions.compactMap { ExtensionPermission(rawValue: $0) })
            if let limits = Optional(result.limits) {
                await connection?.setGeneration(result.generation)
                _ = limits
            }
        case .request(let id, let method, let payload, _, let gen):
            await handleRequest(id: id, method: method, payload: payload, generation: gen)
        case .cancel(let id):
            await connection?.cancel(id: id)
        case .ping:
            try? await connection?.send(.pong)
        default:
            break
        }
    }

    private func handleRequest(
        id: ExtensionRequestID,
        method: ExtensionMethodID,
        payload: Data,
        generation gen: UInt64
    ) async {
        guard let connection else { return }
        if generation != 0 && gen != 0 && gen != generation {
            try? await connection.send(
                .response(
                    id: id,
                    result: nil,
                    error: ExtensionWireError(code: -32009, message: "stale generation"),
                    generation: generation
                ))
            return
        }
        if await connection.isCancelled(id) {
            try? await connection.send(
                .response(
                    id: id, result: nil, error: .cancelled, generation: generation
                ))
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.dispatch(method: method, payload: payload, requestID: id)
                if await connection.isCancelled(id) {
                    try await connection.send(
                        .response(
                            id: id, result: nil, error: .cancelled, generation: await self.generation
                        ))
                } else {
                    try await connection.send(
                        .response(
                            id: id, result: data, error: nil, generation: await self.generation
                        ))
                }
            } catch let err as ExtensionWireError {
                try? await connection.send(
                    .response(
                        id: id, result: nil, error: err, generation: await self.generation
                    ))
            } catch {
                try? await connection.send(
                    .response(
                        id: id,
                        result: nil,
                        error: ExtensionWireError(code: -32000, message: String(describing: error)),
                        generation: await self.generation
                    ))
            }
            await connection.clearInFlight(id: id)
        }
        await connection.trackInFlight(id: id, task: task)
    }

    private func dispatch(
        method: ExtensionMethodID,
        payload: Data,
        requestID: ExtensionRequestID
    ) async throws -> Data {
        switch method {
        case .ping:
            return Data(#"{"ok":true}"#.utf8)
        case .activate:
            if !activated {
                let ctx = GuestExtensionContext(
                    extensionID: ext.manifest.id,
                    grantedPermissions: grantedPermissions,
                    log: log
                )
                context = ctx
                try await ext.activate(in: ctx)
                activated = true
            }
            return Data()
        case .deactivate:
            context?.teardown()
            context = nil
            await ext.deactivate()
            activated = false
            return Data()
        case .completion:
            if let completionHandler { return try await completionHandler(payload) }
            return Data(#"{"items":[]}"#.utf8)
        case .hover:
            if let hoverHandler { return try await hoverHandler(payload) }
            return Data()
        case .definition:
            if let definitionHandler { return try await definitionHandler(payload) }
            return Data("[]".utf8)
        case .diagnostics:
            return Data("[]".utf8)
        case .echo:
            return payload
        case .spawnChild:
            // Spawn a long-lived child for descendant-kill tests.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            childPID = process.processIdentifier
            var info = Data()
            var pid = process.processIdentifier
            withUnsafeBytes(of: &pid) { info.append(contentsOf: $0) }
            return info
        case .lsResolveLaunchPlan, .lsInitializationOptions, .lsWorkspaceConfiguration,
            .lsTransformCompletionLabel, .lsTransformSymbolLabel, .lsStatus, .lsRestart:
            return try await dispatchLanguageServer(method: method, payload: payload)
        case .dapResolveLaunchPlan, .dapResolveConfigurations, .dapLocate, .dapStatus, .dapRestart,
            .mcpResolveLaunchPlan, .mcpStatus, .mcpRestart,
            .slashExecute, .docsSuggest, .docsBuildIndex, .docsInvalidate:
            return try await dispatchPhase13(method: method, payload: payload)
        default:
            // Broker methods: guest forwards are host-handled; guest should not receive them
            // unless acting as host proxy. Return method not found for unhandled.
            if method.rawValue.hasPrefix("broker.") {
                throw ExtensionWireError.methodNotFound
            }
            throw ExtensionWireError.methodNotFound
        }
    }

    private func dispatchLanguageServer(method: ExtensionMethodID, payload: Data) async throws -> Data {
        guard let provider = languageServerProvider else {
            throw ExtensionWireError.methodNotFound
        }
        let extensionID = ext.manifest.id
        switch method {
        case .lsResolveLaunchPlan:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let serverID = obj?["serverID"] as? String ?? ""
            let ctx = LanguageServerResolveContext(extensionID: extensionID)
            let plan = try await provider.resolveLaunchPlan(serverID: serverID, context: ctx)
            return try JSONEncoder().encode(plan)
        case .lsInitializationOptions:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let serverID = obj?["serverID"] as? String ?? ""
            let ctx = LanguageServerResolveContext(extensionID: extensionID)
            return try await provider.initializationOptions(serverID: serverID, context: ctx) ?? Data("{}".utf8)
        case .lsWorkspaceConfiguration:
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let serverID = obj?["serverID"] as? String ?? ""
            let rawItems = obj?["items"] as? [[String: Any]] ?? []
            let items = rawItems.map {
                WorkspaceConfigurationItem(
                    section: $0["section"] as? String,
                    scopeURI: $0["scopeURI"] as? String ?? $0["scopeUri"] as? String
                )
            }
            let results = try await provider.workspaceConfiguration(serverID: serverID, items: items)
            let objs: [Any] = results.map { data -> Any in
                if let data, let o = try? JSONSerialization.jsonObject(with: data) { return o }
                return NSNull()
            }
            return try JSONSerialization.data(withJSONObject: objs)
        case .lsTransformCompletionLabel:
            let item: CompletionLabelTransform
            if let decoded = try? JSONDecoder().decode(CompletionLabelTransform.self, from: payload) {
                item = decoded
            } else {
                let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                item = CompletionLabelTransform(label: obj?["label"] as? String ?? "")
            }
            let out = await provider.transformCompletionLabel(item)
            return try JSONEncoder().encode(out)
        case .lsTransformSymbolLabel:
            let item: SymbolLabelTransform
            if let decoded = try? JSONDecoder().decode(SymbolLabelTransform.self, from: payload) {
                item = decoded
            } else {
                let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                item = SymbolLabelTransform(name: obj?["name"] as? String ?? "")
            }
            let out = await provider.transformSymbolLabel(item)
            return try JSONEncoder().encode(out)
        case .lsStatus:
            return Data(#"{"state":"running"}"#.utf8)
        case .lsRestart:
            return Data(#"{"ok":true}"#.utf8)
        default:
            throw ExtensionWireError.methodNotFound
        }
    }

    private func dispatchPhase13(method: ExtensionMethodID, payload: Data) async throws -> Data {
        let extensionID = ext.manifest.id
        let ctx = LanguageServerResolveContext(extensionID: extensionID)
        switch method {
        case .dapResolveLaunchPlan, .dapResolveConfigurations, .dapLocate, .dapStatus, .dapRestart:
            guard let provider = debugAdapterProvider else {
                throw ExtensionWireError.methodNotFound
            }
            // Guest-side: no host status/restart executors; status/restart require host wiring.
            if method == .dapStatus || method == .dapRestart {
                throw ExtensionWireError(code: -32004, message: "dap status/restart are host-owned")
            }
            if method == .dapLocate {
                guard let locator = debugLocatorProvider else {
                    throw ExtensionWireError.methodNotFound
                }
                let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
                let matches = try await locator.locate(
                    context: DebugLocatorContext(
                        extensionID: extensionID,
                        uri: obj["uri"] as? String,
                        languageID: obj["languageID"] as? String,
                        workspaceRootPaths: obj["workspaceRootPaths"] as? [String] ?? []
                    ))
                return try JSONEncoder().encode(matches)
            }
            if method == .dapResolveLaunchPlan {
                let id =
                    (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["adapterID"] as? String ?? ""
                guard !id.isEmpty else {
                    throw ExtensionWireError(code: -32602, message: "adapterID required")
                }
                let plan = try await provider.resolveLaunchPlan(adapterID: id, context: ctx)
                return try JSONEncoder().encode(plan)
            }
            if method == .dapResolveConfigurations {
                let id =
                    (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["adapterID"] as? String ?? ""
                guard !id.isEmpty else {
                    throw ExtensionWireError(code: -32602, message: "adapterID required")
                }
                let configs = try await provider.resolveConfigurations(adapterID: id, context: ctx)
                return try JSONEncoder().encode(configs)
            }
            throw ExtensionWireError.methodNotFound
        case .mcpResolveLaunchPlan:
            guard let provider = mcpServerProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let id = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["serverID"] as? String ?? ""
            guard !id.isEmpty else {
                throw ExtensionWireError(code: -32602, message: "serverID required")
            }
            let plan = try await provider.resolveLaunchPlan(serverID: id, context: ctx)
            return try JSONEncoder().encode(plan)
        case .mcpStatus, .mcpRestart:
            throw ExtensionWireError(code: -32004, message: "mcp status/restart are host-owned")
        case .slashExecute:
            guard let provider = slashCommandProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let commandID = obj["commandID"] as? String ?? obj["id"] as? String ?? ""
            guard !commandID.isEmpty else {
                throw ExtensionWireError(code: -32602, message: "commandID required")
            }
            let arguments = obj["arguments"] as? String ?? ""
            try SlashCommandSanitize.validateArguments(arguments, maxLength: 4_096)
            var chunks: [SlashCommandChunk] = []
            for try await chunk in provider.execute(
                commandID: commandID,
                arguments: arguments,
                context: SlashCommandExecuteContext(extensionID: extensionID)
            ) {
                chunks.append(
                    SlashCommandChunk(
                        markdown: SlashCommandSanitize.sanitizeMarkdown(chunk.markdown),
                        isFinal: chunk.isFinal
                    ))
            }
            return try JSONEncoder().encode(chunks)
        case .docsSuggest:
            guard let provider = documentationIndexProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let suggestions = try await provider.suggestPackages(context: ctx)
            return try JSONEncoder().encode(suggestions)
        case .docsBuildIndex:
            guard let provider = documentationIndexProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            let packageID = obj["packageID"] as? String ?? obj["id"] as? String ?? ""
            guard !packageID.isEmpty else {
                throw ExtensionWireError(code: -32602, message: "packageID required")
            }
            let suggestion = DocumentationPackageSuggestion(
                id: packageID,
                title: obj["title"] as? String ?? packageID,
                sourcePath: obj["sourcePath"] as? String
            )
            var entries: [DocumentationIndexEntry] = []
            for try await event in provider.buildIndex(package: suggestion, context: ctx) {
                if case .entry(let e) = event { entries.append(e) }
            }
            if entries.isEmpty {
                throw DocumentationIndexError.notFound(packageID)
            }
            return try JSONEncoder().encode(entries)
        case .docsInvalidate:
            guard let provider = documentationIndexProvider else {
                throw ExtensionWireError.methodNotFound
            }
            let packageID =
                (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["packageID"] as? String
            await provider.invalidate(packageID: packageID)
            return try JSONSerialization.data(withJSONObject: ["ok": true])
        default:
            throw ExtensionWireError.methodNotFound
        }
    }
}

/// Minimal author context for native guests (no host registrars).
public final class GuestExtensionContext: ExtensionAuthorContext, @unchecked Sendable {
    public let extensionID: ExtensionID
    public let grantedPermissions: Set<ExtensionPermission>
    public let log: ExtensionLog
    private let lock = NSLock()
    private var disposables: [any ExtensionDisposable] = []

    public init(
        extensionID: ExtensionID,
        grantedPermissions: Set<ExtensionPermission>,
        log: ExtensionLog
    ) {
        self.extensionID = extensionID
        self.grantedPermissions = grantedPermissions
        self.log = log
    }

    public func requirePermission(_ permission: ExtensionPermission) throws {
        guard grantedPermissions.contains(permission) else {
            throw ExtensionError.permissionDenied(permission)
        }
    }

    public func hasPermission(_ permission: ExtensionPermission) -> Bool {
        grantedPermissions.contains(permission)
    }

    public func track(_ disposable: any ExtensionDisposable) {
        lock.lock()
        disposables.append(disposable)
        lock.unlock()
    }

    public func info(_ message: String) {
        log.append(extensionID: extensionID, level: .info, message: message)
    }

    public func warning(_ message: String) {
        log.append(extensionID: extensionID, level: .warning, message: message)
    }

    public func error(_ message: String) {
        log.append(extensionID: extensionID, level: .error, message: message)
    }

    public func teardown() {
        lock.lock()
        let tokens = disposables
        disposables.removeAll()
        lock.unlock()
        for t in tokens.reversed() { t.dispose() }
    }
}

/// Stdio transport for native helper processes.
public final class StdioWireTransport: ExtensionWireTransport, @unchecked Sendable {
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let lock = NSLock()
    private var closed = false
    public let inbound: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?

    public init(stdin: FileHandle = .standardInput, stdout: FileHandle = .standardOutput) {
        self.stdin = stdin
        self.stdout = stdout
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        self.continuation = cont
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                let data = stdin.availableData
                if data.isEmpty {
                    await self?.close()
                    break
                }
                self?.continuation?.yield(data)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func send(_ data: Data) async throws {
        let isClosed = withLock { closed }
        if isClosed { throw ExtensionWireError.transportClosed }
        try stdout.write(contentsOf: data)
    }

    public func close() async {
        let cont: AsyncStream<Data>.Continuation? = withLock {
            if closed { return nil }
            closed = true
            let c = continuation
            continuation = nil
            return c
        }
        readerTask?.cancel()
        cont?.finish()
    }
}

/// Bootstrap helpers for `@main` guest executables.
public enum ExtensionGuestMain {
    public static func run(extension ext: any CodeEditorExtension) async {
        let transport = StdioWireTransport()
        let runtime = ExtensionGuestRuntime(extension: ext, transport: transport)
        await runtime.run()
        // Park until stdin closes / runtime stops.
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Runtime ends when transport closes; sleep loop is fine for helper lifetime.
        }
    }
}
