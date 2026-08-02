import CodeEditorCore
import Foundation

/// JSON-RPC 2.0 bidirectional client over an LSP-framed transport.
///
/// Uses ``OneShotPromise`` for pending requests (register **before** any transport await;
/// LSP-N01). Inbound messages are classified into lanes so responses are never stalled
/// behind slow notification handlers (LSP-N02).
public actor LSPJSONRPCConnection {
    public enum RequestID: Hashable, Sendable {
        case int(Int)
        case string(String)

        init?(json: Any) {
            if let i = json as? Int {
                self = .int(i)
            } else if let n = json as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                self = .int(n.intValue)
            } else if let s = json as? String {
                self = .string(s)
            } else {
                return nil
            }
        }

        var jsonValue: Any {
            switch self {
            case .int(let i): return i
            case .string(let s): return s
            }
        }
    }

    public struct ProgressEvent: Sendable, Hashable {
        public var token: String
        public var kind: String
        public var message: String?
        public var percentage: Int?

        public init(token: String, kind: String, message: String? = nil, percentage: Int? = nil) {
            self.token = token
            self.kind = kind
            self.message = message
            self.percentage = percentage
        }
    }

    /// Inbound message classification (LSP-N02).
    public enum MessageLane: Sendable, Hashable {
        /// Complete pending immediately on the connection actor.
        case response
        /// Stateful notifications that must stay ordered (publishDiagnostics, etc.).
        case stateOrdered
        /// Independent notifications (per-method serial optional).
        case independent
        /// Server→client requests with independent deadlines.
        case serverRequest
    }

    private let transport: any LSPTransport
    private let log: LSPLog
    private var nextID: Int = 1
    /// Pending client requests: installed **before** transport write (LSP-N01).
    private var pending: [RequestID: OneShotPromise<Data>] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String, Data) async -> Void)?
    private var serverRequestHandler: (@Sendable (String, RequestID, Data) async throws -> LSPAnyJSON)?
    private var progressHandler: (@Sendable (ProgressEvent) async -> Void)?
    private let decoder: LSPMessageFraming.Decoder
    private var closed = false
    /// Serial lane for state-ordered notifications (LSP-N02).
    private var stateOrderedChain: Task<Void, Never>?
    /// Per-method serial chains for independent notifications that still need order.
    private var perMethodChains: [String: Task<Void, Never>] = [:]
    /// Bounded concurrent server-request tasks.
    private var serverRequestTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentServerRequests: Int
    public var requestTimeout: Duration
    public private(set) var lastFramingError: LSPMessageFraming.DecodeError?
    /// Legacy metric alias — always 0; early response retention was removed (LSP-N01).
    public private(set) var earlyResponseCount: Int = 0
    /// Late/orphan responses discarded (IDs are not reused).
    public private(set) var lateResponseCount: Int = 0
    public private(set) var duplicateResponseCount: Int = 0

    public init(
        transport: any LSPTransport,
        log: LSPLog = LSPLog(),
        requestTimeout: Duration = .seconds(10),
        maxBodyBytes: Int = LSPMessageFraming.defaultMaxBodyBytes,
        maxConcurrentServerRequests: Int = 16
    ) {
        self.transport = transport
        self.log = log
        self.requestTimeout = requestTimeout
        self.decoder = LSPMessageFraming.Decoder(maxBodyBytes: maxBodyBytes)
        self.maxConcurrentServerRequests = max(1, maxConcurrentServerRequests)
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleInbound(chunk)
            }
            await self?.failAllPending(LSPError.transportClosed)
        }
    }

    public func setNotificationHandler(
        _ handler: @escaping @Sendable (String, Data) async -> Void
    ) {
        notificationHandler = handler
    }

    public func setServerRequestHandler(
        _ handler: @escaping @Sendable (String, RequestID, Data) async throws -> LSPAnyJSON
    ) {
        serverRequestHandler = handler
    }

    public func setProgressHandler(
        _ handler: @escaping @Sendable (ProgressEvent) async -> Void
    ) {
        progressHandler = handler
    }

    public func request<P: Encodable, R: Decodable>(
        _ method: String,
        params: P?
    ) async throws -> R {
        let data = try await requestRaw(method, paramsObject: params.map { try encodeToJSONObject($0) })
        return try decodeResponse(data)
    }

    public func requestDictionary(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> LSPJSONObject {
        let responseData = try await requestRaw(method, paramsObject: params?.dictionary)
        let obj = try JSONSerialization.jsonObject(with: responseData)
        guard let dict = obj as? [String: Any] else {
            throw LSPError.decode("response not object")
        }
        if let error = dict["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "error"
            throw LSPError.serverError(code: code, message: message)
        }
        guard let result = dict["result"] else {
            throw LSPError.decode("missing result")
        }
        // Preserve full JSONValue model (LSP-N11); wrap scalars for dictionary API.
        if let resultDict = result as? [String: Any] {
            return LSPJSONObject(resultDict)
        }
        return LSPJSONObject(["_value": result])
    }

    /// Request returning a complete ``JSONValue`` result (LSP-N11).
    public func requestJSONValue(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> JSONValue {
        let responseData = try await requestRaw(method, paramsObject: params?.dictionary)
        let obj = try JSONSerialization.jsonObject(with: responseData)
        guard let dict = obj as? [String: Any] else {
            throw LSPError.decode("response not object")
        }
        if let error = dict["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "error"
            throw LSPError.serverError(code: code, message: message)
        }
        guard let result = dict["result"] else {
            return .null
        }
        return try JSONValue(jsonObject: result)
    }

    /// Sends `$/cancelRequest` for a client-originated request id.
    public func cancelRequest(id: RequestID) async throws {
        try await notifyDictionary(
            "$/cancelRequest",
            params: LSPJSONObject(["id": id.jsonValue])
        )
    }

    public func notify<P: Encodable>(_ method: String, params: P?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            message["params"] = try encodeToJSONObject(params)
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        try await transport.send(LSPMessageFraming.encode(body))
    }

    public func notifyDictionary(_ method: String, params: LSPJSONObject?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            message["params"] = params.dictionary
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        try await transport.send(LSPMessageFraming.encode(body))
    }

    public func respond(id: RequestID, result: Any?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result as Any? ?? NSNull(),
        ]
        if message["result"] == nil {
            message["result"] = NSNull()
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        try await transport.send(LSPMessageFraming.encode(body))
    }

    public func respondError(id: RequestID, code: Int, message: String) async throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id.jsonValue,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ] as [String: Any])
        try await transport.send(LSPMessageFraming.encode(body))
    }

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        stateOrderedChain?.cancel()
        stateOrderedChain = nil
        for (_, t) in perMethodChains { t.cancel() }
        perMethodChains.removeAll()
        for (_, t) in serverRequestTasks { t.cancel() }
        serverRequestTasks.removeAll()
        await failAllPending(LSPError.transportClosed)
        await transport.close()
    }

    // MARK: - Classification

    public static func classify(
        method: String?,
        hasID: Bool,
        isResponse: Bool
    ) -> MessageLane {
        if isResponse { return .response }
        if hasID, method != nil { return .serverRequest }
        guard let method else { return .independent }
        if isStateOrdered(method) { return .stateOrdered }
        return .independent
    }

    private static func isStateOrdered(_ method: String) -> Bool {
        switch method {
        case "textDocument/publishDiagnostics",
            "workspace/didChangeWorkspaceFolders",
            "workspace/didChangeConfiguration",
            "workspace/didChangeWatchedFiles":
            return true
        default:
            // Custom ordered/* used in tests and any textDocument/* state push.
            if method.hasPrefix("ordered/") { return true }
            if method.hasPrefix("textDocument/") && method.contains("Diagnostic") { return true }
            return false
        }
    }

    // MARK: - Private request lifecycle (LSP-N01)

    /// Register pending **before** any await; no unstructured registration Task.
    private func requestRaw(_ method: String, paramsObject: Any?) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw LSPError.transportClosed }

        let id = RequestID.int(nextID)
        nextID += 1
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "method": method,
        ]
        if let paramsObject {
            message["params"] = paramsObject
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        let framed = LSPMessageFraming.encode(body)

        // Pending record BEFORE any transport await (substrate §22.5 / LSP-N01).
        let promise = OneShotPromise<Data>()
        pending[id] = promise

        do {
            try await transport.send(framed)
        } catch {
            pending[id] = nil
            _ = promise.fail(error)
            throw error
        }

        let deadline = ContinuousClock.now + requestTimeout
        do {
            let value = try await promise.wait(until: deadline)
            pending[id] = nil
            return value
        } catch is CancellationError {
            pending[id] = nil
            _ = promise.fail(CancellationError())
            try? await cancelRequest(id: id)
            throw CancellationError()
        } catch OneShotPromiseError.timedOut {
            pending[id] = nil
            _ = promise.fail(LSPError.timeout(method: method))
            try? await cancelRequest(id: id)
            throw LSPError.timeout(method: method)
        } catch OneShotPromiseError.cancelled {
            pending[id] = nil
            try? await cancelRequest(id: id)
            throw CancellationError()
        } catch {
            pending[id] = nil
            throw error
        }
    }

    private func failPending(id: RequestID, error: Error) {
        if let promise = pending.removeValue(forKey: id) {
            _ = promise.fail(error)
        }
    }

    private func failAllPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, promise) in all {
            _ = promise.fail(error)
        }
    }

    private func handleInbound(_ chunk: Data) {
        let messages = decoder.append(chunk)
        if let err = decoder.lastError {
            lastFramingError = err
            log.append(level: .warning, message: "Framing error: \(err)")
        }
        for body in messages {
            dispatchFrame(body)
        }
    }

    private func dispatchFrame(_ body: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body),
            let dict = obj as? [String: Any]
        else {
            log.append(level: .warning, message: "Invalid JSON-RPC body")
            return
        }

        let idValue = dict["id"]
        let method = dict["method"] as? String
        let hasResultOrError = dict["result"] != nil || dict["error"] != nil
        let isResponse = idValue != nil && method == nil && hasResultOrError
        let lane = Self.classify(
            method: method,
            hasID: idValue != nil,
            isResponse: isResponse
        )

        switch lane {
        case .response:
            completeResponse(idValue: idValue, body: body)
        case .stateOrdered:
            enqueueStateOrdered(body: body, dict: dict, method: method)
        case .independent:
            enqueueIndependent(body: body, dict: dict, method: method)
        case .serverRequest:
            enqueueServerRequest(body: body, dict: dict, method: method, idValue: idValue)
        }
    }

    private func completeResponse(idValue: Any?, body: Data) {
        guard let idValue, let id = RequestID(json: idValue) else { return }
        guard let promise = pending.removeValue(forKey: id) else {
            // Late response: discard and count — never retain for non-reused IDs (LSP-N01).
            lateResponseCount += 1
            log.append(level: .debug, message: "Late/orphan response for \(id)")
            return
        }
        let ok = promise.succeed(body)
        if !ok {
            duplicateResponseCount += 1
        }
    }

    private func enqueueStateOrdered(body: Data, dict: [String: Any], method: String?) {
        let previous = stateOrderedChain
        stateOrderedChain = Task {
            await previous?.value
            await self.deliverNotification(method: method, dict: dict, body: body)
        }
    }

    private func enqueueIndependent(body: Data, dict: [String: Any], method: String?) {
        let key = method ?? ""
        let previous = perMethodChains[key]
        perMethodChains[key] = Task {
            await previous?.value
            await self.deliverNotification(method: method, dict: dict, body: body)
            // Drop finished chain slot when idle (best-effort).
            await self.clearMethodChainIfCurrent(key: key)
        }
    }

    private func clearMethodChainIfCurrent(key: String) {
        // Leave entry; next enqueue chains. No-op cleanup keeps logic simple.
        _ = key
    }

    private func enqueueServerRequest(
        body: Data,
        dict: [String: Any],
        method: String?,
        idValue: Any?
    ) {
        guard let method, let idValue, let id = RequestID(json: idValue) else { return }
        // Bound concurrent server requests: if saturated, still schedule but chain after any.
        if serverRequestTasks.count >= maxConcurrentServerRequests {
            log.append(level: .warning, message: "Server request backlog: \(method)")
        }
        let taskID = UUID()
        let task = Task {
            await self.deliverServerRequest(method: method, id: id, dict: dict, body: body)
            await self.finishServerRequestTask(taskID)
        }
        serverRequestTasks[taskID] = task
    }

    private func finishServerRequestTask(_ id: UUID) {
        serverRequestTasks[id] = nil
    }

    private func deliverNotification(method: String?, dict: [String: Any], body: Data) async {
        guard let method else { return }
        let paramsData: Data
        if let params = dict["params"] {
            paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        } else {
            paramsData = Data("{}".utf8)
        }
        if method == "$/progress" {
            await dispatchProgress(paramsData)
            return
        }
        if let handler = notificationHandler {
            await handler(method, paramsData)
        }
        _ = body
    }

    private func deliverServerRequest(
        method: String,
        id: RequestID,
        dict: [String: Any],
        body: Data
    ) async {
        let paramsData: Data
        if let params = dict["params"] {
            paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
        } else {
            paramsData = Data("{}".utf8)
        }
        _ = body
        await dispatchServerRequest(method: method, id: id, paramsData: paramsData)
    }

    private func dispatchProgress(_ paramsData: Data) async {
        guard
            let obj = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any]
        else { return }
        let token: String
        if let t = obj["token"] as? String {
            token = t
        } else if let t = obj["token"] as? Int {
            token = String(t)
        } else if let t = obj["token"] as? NSNumber {
            token = t.stringValue
        } else {
            token = "unknown"
        }
        let value = obj["value"] as? [String: Any] ?? [:]
        let kind = value["kind"] as? String ?? "report"
        let event = ProgressEvent(
            token: token,
            kind: kind,
            message: value["message"] as? String,
            percentage: value["percentage"] as? Int ?? (value["percentage"] as? NSNumber)?.intValue
        )
        await progressHandler?(event)
        await notificationHandler?("$/progress", paramsData)
    }

    private func dispatchServerRequest(method: String, id: RequestID, paramsData: Data) async {
        guard let handler = serverRequestHandler else {
            log.append(level: .debug, message: "No handler for server request \(method)")
            try? await respondError(id: id, code: -32601, message: "Method not found: \(method)")
            return
        }
        do {
            let result = try await handler(method, id, paramsData)
            try await respond(id: id, result: result.value as Any? ?? NSNull())
        } catch let error as LSPError {
            if case .serverError(let code, let message) = error {
                try? await respondError(id: id, code: code, message: message)
            } else {
                try? await respondError(id: id, code: -32603, message: String(describing: error))
            }
        } catch {
            try? await respondError(id: id, code: -32603, message: String(describing: error))
        }
    }

    private func encodeToJSONObject<P: Encodable>(_ value: P) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func decodeResponse<R: Decodable>(_ data: Data) throws -> R {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw LSPError.decode("response not object")
        }
        if let error = dict["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "error"
            throw LSPError.serverError(code: code, message: message)
        }
        guard let result = dict["result"] else {
            let nullData = Data("null".utf8)
            return try JSONDecoder().decode(R.self, from: nullData)
        }
        // Support scalar results via fragments.
        let resultData = try JSONSerialization.data(
            withJSONObject: result,
            options: [.fragmentsAllowed]
        )
        do {
            return try JSONDecoder().decode(R.self, from: resultData)
        } catch {
            throw LSPError.decode(String(describing: error))
        }
    }
}
