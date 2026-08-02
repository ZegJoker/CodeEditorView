import CodeEditorCore
import CodeEditorExtensionAPI
import Darwin
import Foundation

/// Bounded host-owned MCP client over stdio JSON-RPC (Content-Length framing).
public actor MCPClientSession {
    public let plan: MCPServerLaunchPlan
    public private(set) var state: MCPLifecycleState = .idle
    public private(set) var serverInfo: [String: String] = [:]
    public private(set) var tools: [MCPJSON] = []

    private var transport: (any MCPTransport)?
    private var connection: MCPJSONRPCConnection?
    private var makeTransport: (@Sendable () async throws -> any MCPTransport)?

    public init(
        plan: MCPServerLaunchPlan,
        transportFactory: (@Sendable () async throws -> any MCPTransport)? = nil
    ) {
        self.plan = plan
        self.makeTransport = transportFactory
    }

    public func start() async throws {
        state = .starting
        let transport = try await createTransport()
        self.transport = transport
        let connection = MCPJSONRPCConnection(transport: transport)
        self.connection = connection
        await connection.start()
        let initResult = try await connection.request(
            "initialize",
            params: MCPJSON([
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "CodeEditorView", "version": "1.0"] as [String: Any],
            ])
        )
        if let info = initResult["serverInfo"] as? [String: Any] {
            serverInfo = info.compactMapValues { $0 as? String }
        }
        try await connection.notify("notifications/initialized", params: MCPJSON([:]))
        let toolsResult = try await connection.request("tools/list", params: MCPJSON([:]))
        let arr = toolsResult["tools"] as? [[String: Any]] ?? []
        tools = arr.map { MCPJSON($0) }
        state = .running
    }

    public func callTool(name: String, arguments: MCPJSON = MCPJSON()) async throws -> MCPJSON {
        try await connection!.request(
            "tools/call",
            params: MCPJSON([
                "name": name,
                "arguments": arguments.dictionary,
            ]))
    }

    public func listResources() async throws -> MCPJSON {
        try await connection!.request("resources/list", params: MCPJSON([:]))
    }

    public func listPrompts() async throws -> MCPJSON {
        try await connection!.request("prompts/list", params: MCPJSON([:]))
    }

    public func stop() async {
        await connection?.close()
        connection = nil
        await transport?.close()
        transport = nil
        state = .stopped
    }

    private func createTransport() async throws -> any MCPTransport {
        if let makeTransport { return try await makeTransport() }
        throw MCPClientError.unsupported("MCP transport factory required (test factory or process materialize)")
    }
}

// MARK: - Process transport

/// Stdio process transport for local MCP servers (process-group kill on close).
public final class MCPProcessTransport: MCPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let state = MCPTransportState()
    public let inbound: AsyncStream<Data>
    private var readerTask: Task<Void, Never>?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        platformProfile: PlatformCapabilityProfile = .default()
    ) throws {
        try platformProfile.requireLocal(.localProcess)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont
        self.process = process
        self.stdinPipe = stdinPipe

        try process.run()
        let pid = process.processIdentifier
        if pid > 0 { _ = setpgid(pid, pid) }

        readerTask = Task { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty {
                    await self?.close()
                    break
                }
                self?.state.withLock { $0.continuation }?.yield(data)
            }
        }
        // Drain stderr to avoid blocking
        Task {
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
            }
        }
    }

    public func send(_ data: Data) async throws {
        if state.withLock({ $0.closed }) { throw MCPClientError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        let already = state.withLock { s -> Bool in
            if s.closed { return true }
            s.closed = true
            return false
        }
        if already { return }
        readerTask?.cancel()
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.finish()
        try? stdinPipe.fileHandleForWriting.close()
        let pid = process.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 100_000_000)
            kill(-pid, SIGKILL)
        }
        if process.isRunning { process.terminate() }
    }
}

private final class MCPTransportState: @unchecked Sendable {
    private let lock = NSLock()
    var closed = false
    var continuation: AsyncStream<Data>.Continuation?
    func withLock<T>(_ body: (MCPTransportState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

public enum MCPClientError: Error, Sendable, Equatable {
    case unsupported(String)
    case timeout
    case transportClosed
    case serverError(String)
}

// MARK: - Transport (test pair + framing)

public protocol MCPTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

public final class MCPTestTransport: MCPTransport, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var peer: MCPTestTransport?
        var cont: AsyncStream<Data>.Continuation?
        var closed = false
        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }
    private let state = State()
    public let inbound: AsyncStream<Data>

    public init() {
        var c: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { c = $0 }
        state.cont = c
    }

    public static func makePair() -> (client: MCPTestTransport, server: MCPTestTransport) {
        let a = MCPTestTransport()
        let b = MCPTestTransport()
        a.state.withLock { $0.peer = b }
        b.state.withLock { $0.peer = a }
        return (a, b)
    }

    public func send(_ data: Data) async throws {
        let (closed, peer) = state.withLock { ($0.closed, $0.peer) }
        if closed { throw MCPClientError.transportClosed }
        peer?.state.withLock { $0.cont }?.yield(data)
    }

    public func close() async {
        let c = state.withLock { s -> AsyncStream<Data>.Continuation? in
            s.closed = true
            let c = s.cont
            s.cont = nil
            s.peer = nil
            return c
        }
        c?.finish()
    }
}

/// Sendable JSON object bag for MCP messages.
public struct MCPJSON: @unchecked Sendable {
    public var dictionary: [String: Any]
    public init(_ dictionary: [String: Any] = [:]) { self.dictionary = dictionary }
    public subscript(key: String) -> Any? { dictionary[key] }
}

public actor MCPJSONRPCConnection {
    private let transport: any MCPTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<MCPJSON, Error>] = [:]
    /// Responses that arrived before the matching continuation was registered (register-before-send race window).
    private var earlyResponses: [Int: MCPJSON] = [:]
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var closed = false
    private let requestTimeout: Duration = .seconds(5)

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    public func start() {
        guard reader == nil else { return }
        let stream = transport.inbound
        reader = Task {
            for await chunk in stream {
                await self.handle(chunk)
            }
        }
    }

    public func request(_ method: String, params: MCPJSON) async throws -> MCPJSON {
        let id = nextID
        nextID += 1
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params.dictionary,
        ]
        let body = try JSONSerialization.data(withJSONObject: msg)
        let framed = frame(body)

        // Same contract as LSP-002 / DAP-001: register on the actor *before* send;
        // buffer early responses if the peer answers before register installs.
        do {
            return try await withThrowingTaskGroup(of: MCPJSON.self) { group in
                group.addTask {
                    try await self.executeRegisteredRequest(id: id, framed: framed)
                }
                group.addTask {
                    try await Task.sleep(for: self.requestTimeout)
                    throw MCPClientError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            // Always release any pending continuation so the runtime cannot hang.
            failPending(id: id, error: error)
            throw error
        }
    }

    /// Actor-isolated: install continuation, then write. Resume happens in handle.
    private func executeRegisteredRequest(id: Int, framed: Data) async throws -> MCPJSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MCPJSON, Error>) in
            Task { await self.registerThenSend(id: id, framed: framed, cont: cont) }
        }
    }

    private func registerThenSend(
        id: Int,
        framed: Data,
        cont: CheckedContinuation<MCPJSON, Error>
    ) async {
        if closed {
            cont.resume(throwing: MCPClientError.transportClosed)
            return
        }
        if let early = earlyResponses.removeValue(forKey: id) {
            cont.resume(returning: early)
            return
        }
        // Register **before** any await on the wire.
        pending[id] = cont
        do {
            try await transport.send(framed)
        } catch {
            failPending(id: id, error: error)
        }
    }

    private func failPending(id: Int, error: Error) {
        earlyResponses.removeValue(forKey: id)
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    public func notify(_ method: String, params: MCPJSON) async throws {
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params.dictionary,
        ]
        let body = try JSONSerialization.data(withJSONObject: msg)
        try await transport.send(frame(body))
    }

    public func close() async {
        closed = true
        reader?.cancel()
        reader = nil
        let all = pending
        pending.removeAll()
        earlyResponses.removeAll()
        for (_, c) in all {
            c.resume(throwing: MCPClientError.transportClosed)
        }
        await transport.close()
    }

    private func frame(_ body: Data) -> Data {
        var d = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        d.append(body)
        return d
    }

    private func handle(_ chunk: Data) {
        buffer.append(chunk)
        let sep = Data("\r\n\r\n".utf8)
        while let range = buffer.range(of: sep) {
            let header = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
            var length = 0
            for line in header.split(separator: "\r\n") {
                if line.lowercased().hasPrefix("content-length:") {
                    length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = range.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                let id = (obj["id"] as? Int) ?? (obj["id"] as? NSNumber)?.intValue
            else { continue }

            if let err = obj["error"] as? [String: Any] {
                let error = MCPClientError.serverError(err["message"] as? String ?? "error")
                if let cont = pending.removeValue(forKey: id) {
                    cont.resume(throwing: error)
                }
                // Drop early error if no waiter yet (timeout path will clean up).
                continue
            }
            let result = MCPJSON(obj["result"] as? [String: Any] ?? [:])
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: result)
            } else {
                // Peer answered before registerThenSend installed the waiter — hold it.
                earlyResponses[id] = result
            }
        }
    }
}

/// Mock MCP server for fixtures.
public actor MockMCPServer {
    private let transport: any MCPTransport
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    public private(set) var calls: [String] = []

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    public func start() {
        let stream = transport.inbound
        reader = Task {
            for await chunk in stream {
                await self.handle(chunk)
            }
        }
    }

    public func stop() async {
        reader?.cancel()
        await transport.close()
    }

    private func handle(_ chunk: Data) async {
        buffer.append(chunk)
        let sep = Data("\r\n\r\n".utf8)
        while let range = buffer.range(of: sep) {
            let header = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
            var length = 0
            for line in header.split(separator: "\r\n") {
                if line.lowercased().hasPrefix("content-length:") {
                    length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = range.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            await respond(to: body)
        }
    }

    private func respond(to body: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = obj["method"] as? String
        else { return }
        calls.append(method)
        guard let id = (obj["id"] as? Int) ?? (obj["id"] as? NSNumber)?.intValue else { return }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "mock-mcp", "version": "1.0"],
            ]
        case "tools/list":
            result = [
                "tools": [
                    [
                        "name": "echo",
                        "description": "Echo",
                        "inputSchema": ["type": "object"],
                    ]
                ]
            ]
        case "tools/call":
            let params = obj["params"] as? [String: Any] ?? [:]
            result = [
                "content": [["type": "text", "text": "ok:\(params["name"] as? String ?? "")"]]
            ]
        case "resources/list":
            result = ["resources": [["uri": "mem://a", "name": "A"]]]
        case "prompts/list":
            result = ["prompts": [["name": "hello"]]]
        default:
            result = [:]
        }
        let resp: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        if let data = try? JSONSerialization.data(withJSONObject: resp) {
            var framed = Data("Content-Length: \(data.count)\r\n\r\n".utf8)
            framed.append(data)
            try? await transport.send(framed)
        }
    }
}

public actor MCPServerPool {
    private var sessions: [String: MCPClientSession] = [:]
    private var factories: [String: @Sendable () async throws -> any MCPTransport] = [:]

    public init() {}

    public func registerTestFactory(id: String, factory: @escaping @Sendable () async throws -> any MCPTransport) {
        factories[id] = factory
    }

    public func start(plan: MCPServerLaunchPlan) async throws -> MCPClientSession {
        let factory: (@Sendable () async throws -> any MCPTransport)?
        if case .testFactory(let id) = plan.binarySource {
            guard let f = factories[id] else {
                throw MCPClientError.unsupported("unknown MCP test factory \(id)")
            }
            factory = f
        } else {
            factory = nil
        }
        let session = MCPClientSession(plan: plan, transportFactory: factory)
        sessions[plan.serverID] = session
        try await session.start()
        return session
    }

    public func session(serverID: String) -> MCPClientSession? {
        sessions[serverID]
    }

    public func stop(serverID: String) async {
        await sessions[serverID]?.stop()
        sessions[serverID] = nil
    }
}
