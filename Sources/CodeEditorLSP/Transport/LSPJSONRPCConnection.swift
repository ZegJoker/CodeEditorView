import Foundation

/// JSON-RPC 2.0 client over an LSP-framed transport.
public actor LSPJSONRPCConnection {
    private let transport: any LSPTransport
    private let log: LSPLog
    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// Responses that arrived before the pending continuation was registered.
    private var earlyResponses: [Int: Data] = [:]
    private var readerTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String, Data) async -> Void)?
    private let decoder = LSPMessageFraming.Decoder()
    private var closed = false
    public var requestTimeout: Duration

    public init(
        transport: any LSPTransport,
        log: LSPLog = LSPLog(),
        requestTimeout: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.log = log
        self.requestTimeout = requestTimeout
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

    public func request<P: Encodable, R: Decodable>(
        _ method: String,
        params: P?
    ) async throws -> R {
        let id = nextID
        nextID += 1
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            message["params"] = try encodeToJSONObject(params)
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        let framed = LSPMessageFraming.encode(body)

        try Task.checkCancellation()
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
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

        return try decodeResponse(responseData)
    }

    public func requestDictionary(
        _ method: String,
        params: LSPJSONObject?
    ) async throws -> LSPJSONObject {
        let id = nextID
        nextID += 1
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            message["params"] = params.dictionary
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        let framed = LSPMessageFraming.encode(body)

        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
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

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        await failAllPending(LSPError.transportClosed)
        await transport.close()
    }

    // MARK: - Private

    private func storePending(id: Int, cont: CheckedContinuation<Data, Error>) {
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

    private func failPending(id: Int, error: Error) {
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

        if let idValue = dict["id"] {
            // Response
            let id: Int?
            if let i = idValue as? Int {
                id = i
            } else if let n = idValue as? NSNumber {
                id = n.intValue
            } else {
                id = nil
            }
            if let id {
                if let cont = pending.removeValue(forKey: id) {
                    cont.resume(returning: body)
                } else {
                    earlyResponses[id] = body
                }
            }
            return
        }

        if let method = dict["method"] as? String {
            // Notification or server request (ignore server requests for now except logging)
            let handler = notificationHandler
            let paramsData: Data
            if let params = dict["params"] {
                paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            } else {
                paramsData = Data("{}".utf8)
            }
            if dict["id"] != nil {
                log.append(level: .debug, message: "Ignoring server request \(method)")
                return
            }
            Task {
                await handler?(method, paramsData)
            }
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
            // null result
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
