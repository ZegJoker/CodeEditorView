import Foundation

// MARK: - Framing

/// Content-Length framing used by LSP/DAP-style protocols.
public enum ContentLengthFraming {
    public static let defaultMaxBodyBytes = 16 * 1024 * 1024
    public static let defaultMaxBufferBytes = 20 * 1024 * 1024

    public static func encode(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

public struct ContentLengthFrameDecoder: Sendable {
    private var buffer = Data()
    public let maxBodyBytes: Int
    public let maxBufferBytes: Int
    public private(set) var lastError: FramedRPCError?

    public init(
        maxBodyBytes: Int = ContentLengthFraming.defaultMaxBodyBytes,
        maxBufferBytes: Int = ContentLengthFraming.defaultMaxBufferBytes
    ) {
        let bodyCap = max(1, maxBodyBytes)
        self.maxBodyBytes = bodyCap
        self.maxBufferBytes = max(bodyCap + 1, maxBufferBytes)
    }

    public mutating func append(_ data: Data) -> [Data] {
        lastError = nil
        buffer.append(data)
        if buffer.count > maxBufferBytes {
            lastError = .bufferOverflow(buffer.count)
            buffer.removeAll(keepingCapacity: false)
            return []
        }
        var messages: [Data] = []
        while true {
            do {
                guard let message = try tryExtract() else { break }
                messages.append(message)
            } catch let error as FramedRPCError {
                lastError = error
                buffer.removeAll(keepingCapacity: false)
                break
            } catch {
                lastError = .invalidFrame
                buffer.removeAll(keepingCapacity: false)
                break
            }
        }
        return messages
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        lastError = nil
    }

    private mutating func tryExtract() throws -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
        guard String(data: headerData, encoding: .utf8) != nil else {
            throw FramedRPCError.invalidFrame
        }
        guard let header = String(data: headerData, encoding: .utf8) else {
            throw FramedRPCError.invalidFrame
        }
        var contentLength: Int?
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1])
            }
        }
        guard let length = contentLength, length >= 0 else {
            throw FramedRPCError.invalidFrame
        }
        if length > maxBodyBytes {
            throw FramedRPCError.bodyTooLarge(length)
        }
        let bodyStart = sepRange.upperBound
        let bodyEndOffset = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
        guard bodyEndOffset <= buffer.count else { return nil }
        let bodyEnd = buffer.index(buffer.startIndex, offsetBy: bodyEndOffset)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return body
    }
}

// MARK: - Transport

public protocol ByteTransport: Sendable {
    var inbound: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func close() async
}

/// In-memory duplex transport for tests and in-process peers.
public final class InMemoryByteTransport: ByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    public let inbound: AsyncStream<Data>
    private weak var linked: InMemoryByteTransport?
    private var closed = false

    public init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// The peer that receives this transport's writes.
    public var peer: InMemoryByteTransport {
        if let existing = snapshotLinked() { return existing }
        let other = InMemoryByteTransport()
        link(to: other)
        other.link(to: self)
        return other
    }

    fileprivate func link(to other: InMemoryByteTransport) {
        lock.lock()
        linked = other
        lock.unlock()
    }

    nonisolated private func snapshotLinked() -> InMemoryByteTransport? {
        lock.lock()
        defer { lock.unlock() }
        return linked
    }

    public func write(_ data: Data) async throws {
        let (isClosed, peerCont) = snapshotWriteState()
        if isClosed { throw FramedRPCError.transportClosed }
        peerCont?.yield(data)
    }

    nonisolated private func snapshotWriteState() -> (Bool, AsyncStream<Data>.Continuation?) {
        lock.lock()
        let isClosed = closed
        let peerCont = linked.flatMap { peer -> AsyncStream<Data>.Continuation? in
            peer.lock.lock()
            let c = peer.continuation
            peer.lock.unlock()
            return c
        }
        lock.unlock()
        return (isClosed, peerCont)
    }

    public func close() async {
        let (cont, peer) = sealClose()
        cont?.finish()
        peer?.finishInbound()
    }

    nonisolated private func sealClose() -> (AsyncStream<Data>.Continuation?, InMemoryByteTransport?) {
        lock.lock()
        closed = true
        let cont = continuation
        continuation = nil
        let peer = linked
        lock.unlock()
        return (cont, peer)
    }

    nonisolated private func finishInbound() {
        lock.lock()
        closed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }
}

// MARK: - Codec

public protocol RPCCodec: Sendable {
    associatedtype Method: Sendable
    associatedtype Params: Sendable
    associatedtype ResultValue: Sendable

    func encodeRequest(id: Int, method: Method, params: Params?) throws -> Data
    func encodeNotification(method: Method, params: Params?) throws -> Data
    func decodeResponseID(from body: Data) throws -> Int?
    func decodeResult(from body: Data) throws -> ResultValue
    func decodeError(from body: Data) -> (any Error)?
}

/// JSON-RPC 2.0 codec. Params and results are raw JSON `Data` (Sendable).
public struct JSONRPCCodec: RPCCodec, Sendable {
    public typealias Method = String
    public typealias Params = Data
    public typealias ResultValue = Data

    public init() {}

    public func encodeRequest(id: Int, method: Method, params: Params?) throws -> Data {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            let parsed = try JSONSerialization.jsonObject(with: params)
            obj["params"] = parsed
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [])
    }

    public func encodeNotification(method: Method, params: Params?) throws -> Data {
        var obj: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            let parsed = try JSONSerialization.jsonObject(with: params)
            obj["params"] = parsed
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [])
    }

    public func decodeResponseID(from body: Data) throws -> Int? {
        let obj = try JSONSerialization.jsonObject(with: body)
        guard let dict = obj as? [String: Any] else { return nil }
        if let id = dict["id"] as? Int { return id }
        if let n = dict["id"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.intValue
        }
        return nil
    }

    public func decodeResult(from body: Data) throws -> ResultValue {
        let obj = try JSONSerialization.jsonObject(with: body)
        guard let dict = obj as? [String: Any] else {
            throw FramedRPCError.decodeFailed("not an object")
        }
        if let err = dict["error"] {
            throw FramedRPCError.remoteError(String(describing: err))
        }
        if let result = dict["result"] {
            return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        }
        // null result
        return Data("null".utf8)
    }

    public func decodeError(from body: Data) -> (any Error)? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            obj["error"] != nil
        else { return nil }
        return FramedRPCError.remoteError(String(describing: obj["error"]!))
    }
}

// MARK: - Errors / shutdown

public enum FramedRPCError: Error, Sendable, Equatable {
    case timedOut
    case cancelled
    case transportClosed
    case invalidFrame
    case bodyTooLarge(Int)
    case bufferOverflow(Int)
    case decodeFailed(String)
    case remoteError(String)
    case connectionClosed
}

public enum RPCShutdownReason: Sendable, Hashable {
    case clientShutdown
    case transportFailure
    case protocolError
}

// MARK: - Connection

/// Generic framed RPC engine with one-shot pending records (audit §22.5).
public actor FramedRPCConnection<Codec: RPCCodec, Transport: ByteTransport> {
    private let codec: Codec
    private let transport: Transport
    private var nextID: Int = 1
    private var pending: [Int: OneShotPromise<Codec.ResultValue>] = [:]
    private var readerTask: Task<Void, Never>?
    private var decoder = ContentLengthFrameDecoder()
    private var closed = false
    public private(set) var lateResponseCount: Int = 0
    public private(set) var duplicateResponseCount: Int = 0

    public init(codec: Codec, transport: Transport) {
        self.codec = codec
        self.transport = transport
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleInbound(chunk)
            }
            await self?.failAllPendingAsync(FramedRPCError.transportClosed)
        }
    }

    public func request(
        method: Codec.Method,
        params: Codec.Params?,
        deadline: ContinuousClock.Instant
    ) async throws -> Codec.ResultValue {
        try Task.checkCancellation()
        guard !closed else { throw FramedRPCError.connectionClosed }

        let id = nextID
        nextID &+= 1
        // Pending record BEFORE any transport await (§22.5).
        let promise = OneShotPromise<Codec.ResultValue>()
        pending[id] = promise

        do {
            let body = try codec.encodeRequest(id: id, method: method, params: params)
            try await transport.write(ContentLengthFraming.encode(body))
        } catch {
            pending[id] = nil
            _ = promise.fail(error)
            throw error
        }

        do {
            if Task.isCancelled {
                pending[id] = nil
                _ = promise.fail(FramedRPCError.cancelled)
                throw FramedRPCError.cancelled
            }
            let value = try await promise.wait(until: deadline)
            pending[id] = nil
            return value
        } catch is CancellationError {
            pending[id] = nil
            _ = promise.fail(FramedRPCError.cancelled)
            throw FramedRPCError.cancelled
        } catch OneShotPromiseError.timedOut {
            pending[id] = nil
            _ = promise.fail(FramedRPCError.timedOut)
            throw FramedRPCError.timedOut
        } catch let error as FramedRPCError {
            pending[id] = nil
            throw error
        } catch {
            pending[id] = nil
            throw error
        }
    }

    public func notify(method: Codec.Method, params: Codec.Params?) async throws {
        guard !closed else { throw FramedRPCError.connectionClosed }
        let body = try codec.encodeNotification(method: method, params: params)
        try await transport.write(ContentLengthFraming.encode(body))
    }

    public func close(reason: RPCShutdownReason) async {
        guard !closed else { return }
        closed = true
        _ = reason
        readerTask?.cancel()
        readerTask = nil
        failAllPending(FramedRPCError.connectionClosed)
        await transport.close()
    }

    // MARK: - Private

    private func failAllPendingAsync(_ error: any Error) {
        failAllPending(error)
    }

    private func handleInbound(_ chunk: Data) {
        let frames = decoder.append(chunk)
        for frame in frames {
            handleFrame(frame)
        }
    }

    private func handleFrame(_ body: Data) {
        let id: Int?
        do {
            id = try codec.decodeResponseID(from: body)
        } catch {
            return
        }
        guard let id else { return }
        guard let promise = pending.removeValue(forKey: id) else {
            lateResponseCount += 1
            return
        }
        do {
            if let err = codec.decodeError(from: body) {
                _ = promise.fail(err)
            } else {
                let result = try codec.decodeResult(from: body)
                let ok = promise.succeed(result)
                if !ok {
                    duplicateResponseCount += 1
                }
            }
        } catch {
            _ = promise.fail(error)
        }
    }

    private func failAllPending(_ error: any Error) {
        let all = pending
        pending.removeAll()
        for (_, promise) in all {
            _ = promise.fail(error)
        }
    }
}

// Convenience helpers for JSON-RPC dictionary params.
extension FramedRPCConnection where Codec == JSONRPCCodec {
    public func request(
        method: String,
        params: [String: Any]?,
        deadline: ContinuousClock.Instant
    ) async throws -> Data {
        let paramsData: Data?
        if let params {
            paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
        } else {
            paramsData = nil
        }
        return try await request(method: method, params: paramsData, deadline: deadline)
    }
}
