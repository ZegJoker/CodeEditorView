import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// One running debug adapter connection.
public actor DebugAdapterSession {
    public let definition: DebugAdapterDefinition
    public private(set) var state: DebugAdapterState = .idle
    public private(set) var capabilities: DAPCapabilities = .empty
    public private(set) var restartAttempts: Int = 0

    private let log: DAPLog
    private let budgets: DAPServerBudgets
    private var connection: DAPJSONRPCConnection?
    private var transport: (any DAPTransport)?
    private var makeTransport: (@Sendable () async throws -> any DAPTransport)?

    private var eventContinuation: AsyncStream<(String, DAPJSONObject)>.Continuation?
    public let events: AsyncStream<(String, DAPJSONObject)>

    public var runInTerminalHandler: (any DAPRunInTerminalHandler)?
    public var startDebuggingHandler: (any DAPStartDebuggingHandler)?

    public func setRunInTerminalHandler(_ handler: (any DAPRunInTerminalHandler)?) {
        runInTerminalHandler = handler
    }

    public func setStartDebuggingHandler(_ handler: (any DAPStartDebuggingHandler)?) {
        startDebuggingHandler = handler
    }

    /// Host-owned breakpoint state by source path.
    private var sourceBreakpoints: [String: [DAPSourceBreakpoint]] = [:]

    public init(
        definition: DebugAdapterDefinition,
        log: DAPLog = DAPLog(),
        budgets: DAPServerBudgets = .default,
        transportFactory: (@Sendable () async throws -> any DAPTransport)? = nil
    ) {
        self.definition = definition
        self.log = log
        self.budgets = budgets
        self.makeTransport = transportFactory
        var cont: AsyncStream<(String, DAPJSONObject)>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public var id: DebugAdapterID { definition.id }

    // MARK: - Lifecycle

    public func start() async throws {
        guard state == .idle || state == .stopped || state == .terminated || state == .failed else {
            if state == .running || state == .configured || state == .initialized { return }
            throw DAPError.alreadyStarted
        }
        state = .starting
        do {
            let transport = try await createTransport()
            self.transport = transport
            let connection = DAPJSONRPCConnection(
                transport: transport,
                log: log,
                requestTimeout: budgets.requestTimeout,
                maxBodyBytes: budgets.maxBodyBytes
            )
            self.connection = connection
            await connection.start()
            await connection.setEventHandler { [weak self] event, body in
                await self?.handleEvent(event, body: body)
            }
            await connection.setReverseRequestHandler { [weak self] command, _, args in
                guard let self else { throw DAPError.notRunning }
                return try await self.handleReverseRequest(command: command, args: args)
            }

            let initBody = try await connection.requestDictionary(
                "initialize",
                arguments: DAPJSONObject([
                    "clientID": "codeeditor",
                    "clientName": "CodeEditorView",
                    "adapterID": definition.adapterID,
                    "pathFormat": "path",
                    "linesStartAt1": true,
                    "columnsStartAt1": true,
                    "supportsVariableType": true,
                    "supportsVariablePaging": false,
                    "supportsRunInTerminalRequest": true,
                    "supportsProgressReporting": true,
                    "supportsInvalidatedEvent": true,
                    "locale": "en-US",
                ])
            )
            capabilities = DAPCapabilities.parse(from: initBody.dictionary)
            state = .initialized
            log.append(level: .info, message: "Adapter initialized", adapterID: definition.id.rawValue)
        } catch {
            state = .failed
            log.append(level: .error, message: "Start failed: \(error)", adapterID: definition.id.rawValue)
            await cleanupConnection()
            throw error
        }
    }

    public func launch(configuration: DAPJSONObject, noDebug: Bool = false) async throws {
        try requireInitialized()
        var args = configuration.dictionary
        args["noDebug"] = noDebug
        _ = try await connection?.requestDictionary("launch", arguments: DAPJSONObject(args))
        if capabilities.supportsConfigurationDoneRequest {
            _ = try await connection?.requestDictionary("configurationDone", arguments: DAPJSONObject([:]))
        }
        state = .configured
        state = .running
    }

    public func attach(configuration: DAPJSONObject) async throws {
        try requireInitialized()
        _ = try await connection?.requestDictionary("attach", arguments: configuration)
        if capabilities.supportsConfigurationDoneRequest {
            _ = try await connection?.requestDictionary("configurationDone", arguments: DAPJSONObject([:]))
        }
        state = .configured
        state = .running
    }

    public func disconnect(terminateDebuggee: Bool = true) async {
        if let connection, state != .idle, state != .stopped, state != .terminated {
            _ = try? await connection.requestDictionary(
                "disconnect",
                arguments: DAPJSONObject(["terminateDebuggee": terminateDebuggee])
            )
        }
        await cleanupConnection()
        state = .terminated
    }

    public func terminate() async throws {
        try requireCapability(capabilities.supportsTerminateRequest, "terminate")
        _ = try await connection?.requestDictionary("terminate", arguments: DAPJSONObject([:]))
        state = .terminated
    }

    public func restart(configuration: DAPJSONObject? = nil) async throws {
        if capabilities.supportsRestartRequest {
            _ = try await connection?.requestDictionary(
                "restart",
                arguments: configuration ?? DAPJSONObject([:])
            )
            return
        }
        if restartAttempts >= budgets.restartMaxAttempts {
            throw DAPError.budgetExceeded("restart attempts exhausted")
        }
        restartAttempts += 1
        await disconnect()
        try await start()
        if let configuration {
            try await launch(configuration: configuration)
        }
        restartAttempts = 0
    }

    public func shutdown() async {
        await disconnect()
        state = .stopped
        eventContinuation?.finish()
    }

    // MARK: - Breakpoints

    public func setBreakpoints(sourcePath: String, breakpoints: [DAPSourceBreakpoint]) async throws -> [DAPBreakpoint] {
        try requireRunningLike()
        sourceBreakpoints[sourcePath] = breakpoints
        let args: [String: Any] = [
            "source": ["path": sourcePath] as [String: Any],
            "breakpoints": breakpoints.map { bp -> [String: Any] in
                var d: [String: Any] = ["line": bp.line]
                if let c = bp.column { d["column"] = c }
                if let c = bp.condition { d["condition"] = c }
                if let h = bp.hitCondition { d["hitCondition"] = h }
                if let l = bp.logMessage { d["logMessage"] = l }
                return d
            },
            "sourceModified": false,
        ]
        let body = try await connection!.requestDictionary("setBreakpoints", arguments: DAPJSONObject(args))
        let arr = body["breakpoints"] as? [[String: Any]] ?? []
        return arr.map {
            DAPBreakpoint(
                id: $0["id"] as? Int,
                verified: $0["verified"] as? Bool ?? false,
                message: $0["message"] as? String,
                line: $0["line"] as? Int,
                column: $0["column"] as? Int
            )
        }
    }

    public func setFunctionBreakpoints(_ names: [String]) async throws -> [DAPBreakpoint] {
        try requireCapability(capabilities.supportsFunctionBreakpoints, "setFunctionBreakpoints")
        let body = try await connection!.requestDictionary(
            "setFunctionBreakpoints",
            arguments: DAPJSONObject(["breakpoints": names.map { ["name": $0] }])
        )
        let arr = body["breakpoints"] as? [[String: Any]] ?? []
        return arr.map {
            DAPBreakpoint(
                id: $0["id"] as? Int, verified: $0["verified"] as? Bool ?? false, message: $0["message"] as? String)
        }
    }

    public func setExceptionBreakpoints(filters: [String]) async throws {
        _ = try await connection?.requestDictionary(
            "setExceptionBreakpoints",
            arguments: DAPJSONObject(["filters": filters])
        )
    }

    public func setInstructionBreakpoints(addresses: [String]) async throws -> [DAPBreakpoint] {
        try requireCapability(capabilities.supportsInstructionBreakpoints, "setInstructionBreakpoints")
        let body = try await connection!.requestDictionary(
            "setInstructionBreakpoints",
            arguments: DAPJSONObject(["breakpoints": addresses.map { ["instructionReference": $0] }])
        )
        let arr = body["breakpoints"] as? [[String: Any]] ?? []
        return arr.map {
            DAPBreakpoint(id: $0["id"] as? Int, verified: $0["verified"] as? Bool ?? false)
        }
    }

    public func setDataBreakpoints(dataIds: [String]) async throws -> [DAPBreakpoint] {
        try requireCapability(capabilities.supportsDataBreakpoints, "setDataBreakpoints")
        let body = try await connection!.requestDictionary(
            "setDataBreakpoints",
            arguments: DAPJSONObject(["breakpoints": dataIds.map { ["dataId": $0, "enabled": true] }])
        )
        let arr = body["breakpoints"] as? [[String: Any]] ?? []
        return arr.map {
            DAPBreakpoint(id: $0["id"] as? Int, verified: $0["verified"] as? Bool ?? false)
        }
    }

    // MARK: - Execution control

    public func `continue`(threadId: Int) async throws {
        try requireRunningLike()
        _ = try await connection?.requestDictionary("continue", arguments: DAPJSONObject(["threadId": threadId]))
        state = .running
    }

    public func next(threadId: Int) async throws {
        _ = try await connection?.requestDictionary("next", arguments: DAPJSONObject(["threadId": threadId]))
    }

    public func stepIn(threadId: Int) async throws {
        _ = try await connection?.requestDictionary("stepIn", arguments: DAPJSONObject(["threadId": threadId]))
    }

    public func stepOut(threadId: Int) async throws {
        _ = try await connection?.requestDictionary("stepOut", arguments: DAPJSONObject(["threadId": threadId]))
    }

    public func pause(threadId: Int) async throws {
        _ = try await connection?.requestDictionary("pause", arguments: DAPJSONObject(["threadId": threadId]))
    }

    // MARK: - Inspection

    public func threads() async throws -> [DAPThread] {
        let body = try await connection!.requestDictionary("threads", arguments: DAPJSONObject([:]))
        let arr = body["threads"] as? [[String: Any]] ?? []
        return arr.compactMap { d in
            guard let id = d["id"] as? Int, let name = d["name"] as? String else { return nil }
            return DAPThread(id: id, name: name)
        }
    }

    public func stackTrace(threadId: Int, startFrame: Int = 0, levels: Int = 20) async throws -> [DAPStackFrame] {
        let body = try await connection!.requestDictionary(
            "stackTrace",
            arguments: DAPJSONObject([
                "threadId": threadId,
                "startFrame": startFrame,
                "levels": levels,
            ])
        )
        let arr = body["stackFrames"] as? [[String: Any]] ?? []
        return arr.compactMap { d in
            guard let id = d["id"] as? Int, let name = d["name"] as? String else { return nil }
            let line = d["line"] as? Int ?? 0
            let column = d["column"] as? Int ?? 0
            let path = (d["source"] as? [String: Any])?["path"] as? String
            return DAPStackFrame(id: id, name: name, line: line, column: column, sourcePath: path)
        }
    }

    public func scopes(frameId: Int) async throws -> [DAPScope] {
        let body = try await connection!.requestDictionary(
            "scopes",
            arguments: DAPJSONObject(["frameId": frameId])
        )
        let arr = body["scopes"] as? [[String: Any]] ?? []
        return arr.compactMap { d in
            guard let name = d["name"] as? String,
                let ref = d["variablesReference"] as? Int
            else { return nil }
            return DAPScope(name: name, variablesReference: ref, expensive: d["expensive"] as? Bool ?? false)
        }
    }

    public func variables(variablesReference: Int) async throws -> [DAPVariable] {
        let body = try await connection!.requestDictionary(
            "variables",
            arguments: DAPJSONObject(["variablesReference": variablesReference])
        )
        let arr = body["variables"] as? [[String: Any]] ?? []
        return arr.compactMap { d in
            guard let name = d["name"] as? String, let value = d["value"] as? String else { return nil }
            return DAPVariable(
                name: name,
                value: value,
                type: d["type"] as? String,
                variablesReference: d["variablesReference"] as? Int ?? 0
            )
        }
    }

    public func evaluate(expression: String, frameId: Int?, context: String = "repl") async throws -> DAPVariable {
        var args: [String: Any] = ["expression": expression, "context": context]
        if let frameId { args["frameId"] = frameId }
        let body = try await connection!.requestDictionary("evaluate", arguments: DAPJSONObject(args))
        return DAPVariable(
            name: expression,
            value: body["result"] as? String ?? "",
            type: body["type"] as? String,
            variablesReference: body["variablesReference"] as? Int ?? 0
        )
    }

    public func setVariable(variablesReference: Int, name: String, value: String) async throws -> DAPVariable {
        try requireCapability(capabilities.supportsSetVariable, "setVariable")
        let body = try await connection!.requestDictionary(
            "setVariable",
            arguments: DAPJSONObject([
                "variablesReference": variablesReference,
                "name": name,
                "value": value,
            ])
        )
        return DAPVariable(
            name: name,
            value: body["value"] as? String ?? value,
            type: body["type"] as? String,
            variablesReference: body["variablesReference"] as? Int ?? 0
        )
    }

    public func source(sourceReference: Int) async throws -> String {
        let body = try await connection!.requestDictionary(
            "source",
            arguments: DAPJSONObject(["sourceReference": sourceReference])
        )
        return body["content"] as? String ?? ""
    }

    public func modules() async throws -> DAPJSONObject {
        try requireCapability(capabilities.supportsModulesRequest, "modules")
        return try await connection!.requestDictionary("modules", arguments: DAPJSONObject([:]))
    }

    public func loadedSources() async throws -> DAPJSONObject {
        try requireCapability(capabilities.supportsLoadedSourcesRequest, "loadedSources")
        return try await connection!.requestDictionary("loadedSources", arguments: DAPJSONObject([:]))
    }

    public func disassemble(memoryReference: String, instructionCount: Int = 16) async throws -> DAPJSONObject {
        try requireCapability(capabilities.supportsDisassembleRequest, "disassemble")
        return try await connection!.requestDictionary(
            "disassemble",
            arguments: DAPJSONObject([
                "memoryReference": memoryReference,
                "instructionCount": instructionCount,
            ])
        )
    }

    public func readMemory(memoryReference: String, count: Int) async throws -> String {
        try requireCapability(capabilities.supportsReadMemoryRequest, "readMemory")
        let body = try await connection!.requestDictionary(
            "readMemory",
            arguments: DAPJSONObject([
                "memoryReference": memoryReference,
                "count": count,
            ])
        )
        return body["data"] as? String ?? ""
    }

    public func writeMemory(memoryReference: String, data: String) async throws {
        try requireCapability(capabilities.supportsWriteMemoryRequest, "writeMemory")
        _ = try await connection?.requestDictionary(
            "writeMemory",
            arguments: DAPJSONObject([
                "memoryReference": memoryReference,
                "data": data,
            ])
        )
    }

    public func completions(text: String, column: Int, frameId: Int?) async throws -> DAPJSONObject {
        try requireCapability(capabilities.supportsCompletionsRequest, "completions")
        var args: [String: Any] = ["text": text, "column": column]
        if let frameId { args["frameId"] = frameId }
        return try await connection!.requestDictionary("completions", arguments: DAPJSONObject(args))
    }

    // MARK: - Private

    private func createTransport() async throws -> any DAPTransport {
        if let makeTransport {
            return try await makeTransport()
        }
        switch definition.launch {
        case .process(let executable, let arguments):
            return try DAPProcessTransport(
                executable: executable,
                arguments: arguments,
                environment: definition.environment.isEmpty ? nil : definition.environment,
                currentDirectory: definition.currentDirectory
            )
        case .test(let factoryID):
            throw DAPError.unsupported("test factory \(factoryID) requires pool registration")
        case .connect:
            throw DAPError.unsupported("TCP connect transport: use custom factory in host")
        case .custom(let factory):
            return try await factory()
        }
    }

    private func handleEvent(_ event: String, body: DAPJSONObject) {
        eventContinuation?.yield((event, body))
        switch event {
        case "stopped":
            state = .stopped
        case "continued":
            state = .running
        case "terminated", "exited":
            state = .terminated
        default:
            break
        }
    }

    private func handleReverseRequest(command: String, args: DAPJSONObject) async throws -> DAPJSONObject {
        switch command {
        case "runInTerminal":
            guard let handler = runInTerminalHandler else {
                throw DAPError.unsupported("runInTerminal handler not set")
            }
            let d = args.dictionary
            let terminalArgs = DAPRunInTerminalArgs(
                kind: d["kind"] as? String,
                title: d["title"] as? String,
                cwd: d["cwd"] as? String,
                args: d["args"] as? [String] ?? [],
                env: d["env"] as? [String: String]
            )
            let result = try await handler.runInTerminal(args: terminalArgs)
            var body: [String: Any] = [:]
            if let pid = result.processId { body["processId"] = pid }
            if let spid = result.shellProcessId { body["shellProcessId"] = spid }
            return DAPJSONObject(body)
        case "startDebugging":
            guard let handler = startDebuggingHandler else {
                throw DAPError.unsupported("startDebugging handler not set")
            }
            let d = args.dictionary
            let configDict = d["configuration"] as? [String: Any] ?? [:]
            let request = d["request"] as? String ?? "launch"
            try await handler.startDebugging(configuration: DAPJSONObject(configDict), request: request)
            return DAPJSONObject([:])
        default:
            throw DAPError.unsupported("reverse request \(command)")
        }
    }

    private func cleanupConnection() async {
        await connection?.close()
        connection = nil
        await transport?.close()
        transport = nil
    }

    private func requireInitialized() throws {
        guard state == .initialized || state == .configured || state == .running || state == .stopped else {
            throw DAPError.notInitialized
        }
    }

    private func requireRunningLike() throws {
        guard state == .running || state == .stopped || state == .configured || state == .initialized else {
            throw DAPError.notRunning
        }
    }

    private func requireCapability(_ enabled: Bool, _ name: String) throws {
        if !enabled { throw DAPError.capabilityUnavailable(name) }
    }
}
