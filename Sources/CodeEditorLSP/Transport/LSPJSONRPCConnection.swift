import Foundation

/// JSON-RPC 2.0 bidirectional client over an LSP-framed transport.
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

    private let transport: any LSPTransport
    private let log: LSPLog
    private var nextID: Int = 1
    private var pending: [RequestID: CheckedContinuation<Data, Error>] = [:]
    /// Responses that arrived before the pending continuation was registered.
    private var earlyResponses: [RequestID: Data] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String, Data) async -> Void)?
    /// Handles server→client requests; return JSON-serializable result or throw.
    private var serverRequestHandler: (@Sendable (String, RequestID, Data) async throws -> LSPAnyJSON)?
    private var progressHandler: (@Sendable (ProgressEvent) async -> Void)?
    private let decoder: LSPMessageFraming.Decoder
    private var closed = false
    public var requestTimeout: Duration
    public private(set) var lastFramingError: LSPMessageFraming.DecodeError?

    public init(
        transport: any LSPTransport,
        log: LSPLog = LSPLog(),
        requestTimeout: Duration = .seconds(10),
        maxBodyBytes: Int = LSPMessageFraming.defaultMaxBodyBytes
    ) {
        self.transport = transport
        self.log = log
        self.requestTimeout = requestTimeout
        self.decoder = LSPMessageFraming.Decoder(maxBodyBytes: maxBodyBytes)
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
        if let resultDict = result as? [String: Any] {
            return LSPJSONObject(resultDict)
        }
        return LSPJSONObject(["_value": result])
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
        // JSONSerialization rejects top-level Optional; ensure NSNull.
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
        await failAllPending(LSPError.transportClosed)
        await transport.close()
    }

    // MARK: - Private

    private func requestRaw(_ method: String, paramsObject: Any?) async throws -> Data {
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

        try Task.checkCancellation()
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                        Task {
                            await self.storePending(id: id, cont: cont)
                            do {
                                try await self.transport.send(framed)
                            } catch {
                                await self.failPending(id: id, error: error)
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: self.requestTimeout)
                    throw LSPError.timeout(method: method)
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            try? await cancelRequest(id: id)
            failPending(id: id, error: CancellationError())
            throw CancellationError()
        } catch let error as LSPError {
            if case .timeout = error {
                try? await cancelRequest(id: id)
                failPending(id: id, error: error)
            }
            throw error
        }
    }

    private func storePending(id: RequestID, cont: CheckedContinuation<Data, Error>) {
        if closed {
            cont.resume(throwing: LSPError.transportClosed)
            return
        }
        if let early = earlyResponses.removeValue(forKey: id) {
            cont.resume(returning: early)
            return
        }
        pending[id] = cont
    }

    private func failPending(id: RequestID, error: Error) {
        earlyResponses.removeValue(forKey: id)
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAllPending(_ error: Error) {
        let all = pending
        pending.removeAll()
        earlyResponses.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: error)
        }
    }

    private func handleInbound(_ chunk: Data) {
        let messages = decoder.append(chunk)
        if let err = decoder.lastError {
            lastFramingError = err
            log.append(level: .warning, message: "Framing error: \(err)")
        }
        for body in messages {
            handleMessage(body)
        }
    }

    private func handleMessage(_ body: Data) {
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

        // Response to client request
        if let idValue, method == nil, hasResultOrError {
            if let id = RequestID(json: idValue) {
                if let cont = pending.removeValue(forKey: id) {
                    cont.resume(returning: body)
                } else {
                    earlyResponses[id] = body
                }
            }
            return
        }

        // Notification or server request
        if let method {
            let paramsData: Data
            if let params = dict["params"] {
                paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            } else {
                paramsData = Data("{}".utf8)
            }

            // Progress notifications
            if method == "$/progress" {
                Task { await self.dispatchProgress(paramsData) }
                return
            }

            if let idValue, let id = RequestID(json: idValue) {
                // Server → client request
                Task { await self.dispatchServerRequest(method: method, id: id, paramsData: paramsData) }
                return
            }

            // Notification
            let handler = notificationHandler
            Task {
                await handler?(method, paramsData)
            }
            return
        }
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
        let resultData = try JSONSerialization.data(withJSONObject: result)
        do {
            return try JSONDecoder().decode(R.self, from: resultData)
        } catch {
            throw LSPError.decode(String(describing: error))
        }
    }
}
