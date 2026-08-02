import Foundation

/// Bidirectional JSON-RPC 2.0 over DAP Content-Length framing.
public actor DAPJSONRPCConnection {
    public enum RequestID: Hashable, Sendable {
        case int(Int)
        case string(String)

        init?(json: Any) {
            if let i = json as? Int {
                self = .int(i)
                return
            }
            if let n = json as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                self = .int(n.intValue)
                return
            }
            if let s = json as? String {
                self = .string(s)
                return
            }
            return nil
        }

        var jsonValue: Any {
            switch self {
            case .int(let i): return i
            case .string(let s): return s
            }
        }
    }

    private let transport: any DAPTransport
    private let log: DAPLog
    private var nextID: Int = 1
    private var pending: [RequestID: CheckedContinuation<Data, Error>] = [:]
    private var earlyResponses: [RequestID: Data] = [:]
    private var readerTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (String, DAPJSONObject) async -> Void)?
    private var reverseRequestHandler: (@Sendable (String, RequestID, DAPJSONObject) async throws -> DAPJSONObject)?
    private let decoder: DAPMessageFraming.Decoder
    private var closed = false
    public var requestTimeout: Duration
    public private(set) var lastFramingError: DAPMessageFraming.DecodeError?

    public init(
        transport: any DAPTransport,
        log: DAPLog = DAPLog(),
        requestTimeout: Duration = .seconds(15),
        maxBodyBytes: Int = DAPMessageFraming.defaultMaxBodyBytes
    ) {
        self.transport = transport
        self.log = log
        self.requestTimeout = requestTimeout
        self.decoder = DAPMessageFraming.Decoder(maxBodyBytes: maxBodyBytes)
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleInbound(chunk)
            }
            await self?.failAllPending(DAPError.transportClosed)
        }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (String, DAPJSONObject) async -> Void) {
        eventHandler = handler
    }

    public func setReverseRequestHandler(
        _ handler: @escaping @Sendable (String, RequestID, DAPJSONObject) async throws -> DAPJSONObject
    ) {
        reverseRequestHandler = handler
    }

    public func requestDictionary(_ command: String, arguments: DAPJSONObject? = nil) async throws -> DAPJSONObject {
        let data = try await requestRaw(command: command, arguments: arguments)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw DAPError.decode("response not object")
        }
        // DAP response: { seq, type:"response", request_seq, success, command, body?, message? }
        if let success = dict["success"] as? Bool, !success {
            let msg = dict["message"] as? String ?? "adapter error"
            throw DAPError.adapterError(code: (dict["body"] as? [String: Any])?["error"] as? Int ?? -1, message: msg)
        }
        if let body = dict["body"] as? [String: Any] {
            return DAPJSONObject(body)
        }
        return DAPJSONObject([:])
    }

    public func requestRaw(command: String, arguments: DAPJSONObject? = nil) async throws -> Data {
        if closed { throw DAPError.transportClosed }
        let id = RequestID.int(nextID)
        nextID += 1
        var message: [String: Any] = [
            "seq": {
                if case .int(let i) = id { return i }
                return 0
            }(),
            "type": "request",
            "command": command,
        ]
        if let arguments {
            message["arguments"] = arguments.dictionary
        }
        let body = try JSONSerialization.data(withJSONObject: message)
        let framed = DAPMessageFraming.encode(body)

        // DAP-001 / §14.1: register-before-send on this actor (mirrors LSP-002).
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.executeRegisteredRequest(id: id, framed: framed)
            }
            group.addTask {
                try await Task.sleep(for: self.requestTimeout)
                throw DAPError.timeout(method: command)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                await self.failPending(id: id, error: error)
                throw error
            }
        }
    }

    /// Actor-isolated: install continuation, then write. Resume happens in dispatchMessage.
    private func executeRegisteredRequest(id: RequestID, framed: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await self.registerPendingThenSend(id: id, framed: framed, cont: cont) }
        }
    }

    private func registerPendingThenSend(
        id: RequestID,
        framed: Data,
        cont: CheckedContinuation<Data, Error>
    ) async {
        if closed {
            cont.resume(throwing: DAPError.transportClosed)
            return
        }
        if let early = earlyResponses.removeValue(forKey: id) {
            cont.resume(returning: early)
            return
        }
        // Register **before** any await on the wire (DAP-001).
        pending[id] = cont
        do {
            try await transport.send(framed)
        } catch {
            failPending(id: id, error: error)
        }
    }

    private func failPending(id: RequestID, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
        earlyResponses.removeValue(forKey: id)
    }

    private func removePending(id: RequestID) {
        pending.removeValue(forKey: id)
        earlyResponses.removeValue(forKey: id)
    }

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        failAllPending(DAPError.transportClosed)
        await transport.close()
    }

    private func failAllPending(_ error: DAPError) {
        let all = pending
        pending.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: error)
        }
    }

    /// Serial inbound chain (DAP-002 / §14.2) — preserve event order.
    private var inboundChain: Task<Void, Never>?
    private let maxEarlyResponses = 8
    public private(set) var earlyResponseCount: Int = 0

    private func handleInbound(_ chunk: Data) {
        let messages = decoder.append(chunk)
        if let err = decoder.lastError {
            lastFramingError = err
            log.append(level: .warning, message: "framing: \(err)")
        }
        let previous = inboundChain
        inboundChain = Task {
            await previous?.value
            for message in messages {
                await self.dispatchMessage(message)
            }
        }
    }

    private func dispatchMessage(_ body: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        switch type {
        case "response":
            let reqSeq =
                (obj["request_seq"] as? Int)
                ?? (obj["request_seq"] as? NSNumber)?.intValue
            guard let reqSeq else { return }
            let id = RequestID.int(reqSeq)
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: body)
            } else {
                earlyResponseCount += 1
                if earlyResponses.count < maxEarlyResponses {
                    earlyResponses[id] = body
                }
            }
        case "event":
            let event = obj["event"] as? String ?? ""
            let bodyDict = obj["body"] as? [String: Any] ?? [:]
            await eventHandler?(event, DAPJSONObject(bodyDict))
        case "request":
            // Reverse request from adapter
            guard let command = obj["command"] as? String else { return }
            let seq = (obj["seq"] as? Int) ?? (obj["seq"] as? NSNumber)?.intValue ?? 0
            guard seq != 0 || obj["seq"] != nil else { return }
            let id = RequestID.int(seq)
            let args = DAPJSONObject(obj["arguments"] as? [String: Any] ?? [:])
            do {
                let result = try await reverseRequestHandler?(command, id, args) ?? DAPJSONObject([:])
                try await sendReverseResponse(seq: seq, command: command, success: true, body: result.dictionary)
            } catch {
                try? await sendReverseResponse(
                    seq: seq,
                    command: command,
                    success: false,
                    message: String(describing: error)
                )
            }
        default:
            break
        }
    }

    private func sendReverseResponse(
        seq: Int,
        command: String,
        success: Bool,
        body: Any? = nil,
        message: String? = nil
    ) async throws {
        var messageObj: [String: Any] = [
            "seq": nextID,
            "type": "response",
            "request_seq": seq,
            "success": success,
            "command": command,
        ]
        nextID += 1
        if let body { messageObj["body"] = body }
        if let message { messageObj["message"] = message }
        let data = try JSONSerialization.data(withJSONObject: messageObj)
        try await transport.send(DAPMessageFraming.encode(data))
    }
}
