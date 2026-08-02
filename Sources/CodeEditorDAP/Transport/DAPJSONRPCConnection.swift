import CodeEditorCore
import Foundation

/// Bidirectional DAP JSON-RPC over Content-Length framing.
///
/// Uses ``OneShotPromise`` for pending requests (register **before** any transport await;
/// DAP-N01). Late/orphan responses are discarded (DAP-N02). Inbound messages are classified
/// into lanes so responses never wait behind slow events or reverse requests (DAP-N03).
/// Missing reverse handlers return a failed DAP response, never empty success (DAP-N04).
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

    /// Inbound message classification (DAP-N03).
    public enum MessageLane: Sendable, Hashable {
        /// Complete pending immediately on the connection actor.
        case response
        /// Lifecycle events that must stay ordered (stopped/continued/terminated/…).
        case stateOrdered
        /// Independent events (output, progress, custom).
        case independent
        /// Adapter→client reverse requests with independent execution.
        case reverseRequest
    }

    private let transport: any DAPTransport
    private let log: DAPLog
    private var nextID: Int = 1
    /// Pending client requests: installed **before** transport write (DAP-N01).
    private var pending: [RequestID: OneShotPromise<Data>] = [:]
    private var readerTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (String, DAPJSONObject) async -> Void)?
    private var reverseRequestHandler: (@Sendable (String, RequestID, DAPJSONObject) async throws -> DAPJSONObject)?
    private let decoder: DAPMessageFraming.Decoder
    private var closed = false
    /// Serial lane for state-ordered events (DAP-N03).
    private var stateOrderedChain: Task<Void, Never>?
    /// Per-event-name serial chains for independent events.
    private var perEventChains: [String: Task<Void, Never>] = [:]
    /// Concurrent reverse-request tasks.
    private var reverseRequestTasks: [UUID: Task<Void, Never>] = [:]
    private let maxConcurrentReverseRequests: Int
    public var requestTimeout: Duration
    public private(set) var lastFramingError: DAPMessageFraming.DecodeError?
    /// Legacy metric alias — always 0; early response retention was removed (DAP-N01/N02).
    public private(set) var earlyResponseCount: Int = 0
    /// Late/orphan responses discarded (IDs are not reused).
    public private(set) var lateResponseCount: Int = 0
    public private(set) var duplicateResponseCount: Int = 0

    public init(
        transport: any DAPTransport,
        log: DAPLog = DAPLog(),
        requestTimeout: Duration = .seconds(15),
        maxBodyBytes: Int = DAPMessageFraming.defaultMaxBodyBytes,
        maxConcurrentReverseRequests: Int = 16
    ) {
        self.transport = transport
        self.log = log
        self.requestTimeout = requestTimeout
        self.decoder = DAPMessageFraming.Decoder(maxBodyBytes: maxBodyBytes)
        self.maxConcurrentReverseRequests = max(1, maxConcurrentReverseRequests)
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
            throw DAPError.adapterError(
                code: (dict["body"] as? [String: Any])?["error"] as? Int ?? -1,
                message: msg
            )
        }
        if let body = dict["body"] as? [String: Any] {
            return DAPJSONObject(body)
        }
        return DAPJSONObject([:])
    }

    public func requestRaw(command: String, arguments: DAPJSONObject? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw DAPError.transportClosed }

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

        // Pending record BEFORE any transport await (substrate §22.5 / DAP-N01).
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
            throw CancellationError()
        } catch OneShotPromiseError.timedOut {
            pending[id] = nil
            _ = promise.fail(DAPError.timeout(method: command))
            throw DAPError.timeout(method: command)
        } catch OneShotPromiseError.cancelled {
            pending[id] = nil
            throw CancellationError()
        } catch {
            pending[id] = nil
            throw error
        }
    }

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        stateOrderedChain?.cancel()
        stateOrderedChain = nil
        for (_, t) in perEventChains { t.cancel() }
        perEventChains.removeAll()
        for (_, t) in reverseRequestTasks { t.cancel() }
        reverseRequestTasks.removeAll()
        failAllPending(DAPError.transportClosed)
        await transport.close()
    }

    // MARK: - Classification

    public static func classify(type: String, event: String?, command: String?) -> MessageLane {
        switch type {
        case "response":
            return .response
        case "request":
            return .reverseRequest
        case "event":
            if let event, isStateOrdered(event) {
                return .stateOrdered
            }
            return .independent
        default:
            return .independent
        }
    }

    private static func isStateOrdered(_ event: String) -> Bool {
        switch event {
        case "initialized", "stopped", "continued", "terminated", "exited",
            "thread", "process", "module", "loadedSource", "capabilities",
            "breakpoint", "invalidated":
            return true
        default:
            if event.hasPrefix("ordered/") { return true }
            return false
        }
    }

    // MARK: - Private

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
            log.append(level: .warning, message: "framing: \(err)")
        }
        for body in messages {
            dispatchFrame(body)
        }
    }

    private func dispatchFrame(_ body: Data) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let type = obj["type"] as? String
        else {
            log.append(level: .warning, message: "Invalid DAP body")
            return
        }

        let event = obj["event"] as? String
        let command = obj["command"] as? String
        let lane = Self.classify(type: type, event: event, command: command)

        switch lane {
        case .response:
            completeResponse(obj: obj, body: body)
        case .stateOrdered:
            enqueueStateOrdered(obj: obj)
        case .independent:
            enqueueIndependent(obj: obj)
        case .reverseRequest:
            enqueueReverseRequest(obj: obj)
        }
    }

    private func completeResponse(obj: [String: Any], body: Data) {
        let reqSeq =
            (obj["request_seq"] as? Int)
            ?? (obj["request_seq"] as? NSNumber)?.intValue
        guard let reqSeq else { return }
        let id = RequestID.int(reqSeq)
        guard let promise = pending.removeValue(forKey: id) else {
            // Late response: discard and count — never retain (DAP-N02).
            lateResponseCount += 1
            log.append(level: .debug, message: "Late/orphan response for request_seq=\(reqSeq)")
            return
        }
        let ok = promise.succeed(body)
        if !ok {
            duplicateResponseCount += 1
        }
    }

    private func enqueueStateOrdered(obj: [String: Any]) {
        let previous = stateOrderedChain
        stateOrderedChain = Task {
            await previous?.value
            await self.deliverEvent(obj: obj)
        }
    }

    private func enqueueIndependent(obj: [String: Any]) {
        let key = (obj["event"] as? String) ?? "event"
        let previous = perEventChains[key]
        perEventChains[key] = Task {
            await previous?.value
            await self.deliverEvent(obj: obj)
        }
    }

    private func enqueueReverseRequest(obj: [String: Any]) {
        guard let command = obj["command"] as? String else { return }
        let seq = (obj["seq"] as? Int) ?? (obj["seq"] as? NSNumber)?.intValue ?? 0
        guard seq != 0 || obj["seq"] != nil else { return }
        if reverseRequestTasks.count >= maxConcurrentReverseRequests {
            log.append(level: .warning, message: "Reverse request backlog: \(command)")
        }
        let taskID = UUID()
        let task = Task {
            await self.deliverReverseRequest(command: command, seq: seq, obj: obj)
            await self.finishReverseRequestTask(taskID)
        }
        reverseRequestTasks[taskID] = task
    }

    private func finishReverseRequestTask(_ id: UUID) {
        reverseRequestTasks[id] = nil
    }

    private func deliverEvent(obj: [String: Any]) async {
        let event = obj["event"] as? String ?? ""
        let bodyDict = obj["body"] as? [String: Any] ?? [:]
        await eventHandler?(event, DAPJSONObject(bodyDict))
    }

    private func deliverReverseRequest(command: String, seq: Int, obj: [String: Any]) async {
        let id = RequestID.int(seq)
        let args = DAPJSONObject(obj["arguments"] as? [String: Any] ?? [:])
        guard let handler = reverseRequestHandler else {
            // DAP-N04: fail closed — never empty success when no handler.
            log.append(level: .debug, message: "No reverse handler for \(command)")
            try? await sendReverseResponse(
                seq: seq,
                command: command,
                success: false,
                message: "Method not found: no reverse handler for \(command)"
            )
            return
        }
        do {
            let result = try await handler(command, id, args)
            try await sendReverseResponse(
                seq: seq,
                command: command,
                success: true,
                body: result.dictionary
            )
        } catch {
            try? await sendReverseResponse(
                seq: seq,
                command: command,
                success: false,
                message: String(describing: error)
            )
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
