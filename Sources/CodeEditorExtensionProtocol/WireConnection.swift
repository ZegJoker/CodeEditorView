import Foundation

/// Byte duplex used by host and guest connections.
public protocol ExtensionWireTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

/// CBOR-framed request/response connection with cancel, progress, and generation checks.
public actor ExtensionWireConnection {
    private let transport: any ExtensionWireTransport
    private let decoder: CBORFraming.Decoder
    private var readerTask: Task<Void, Never>?
    private var pending: [UUID: CheckedContinuation<ExtensionEnvelope, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    public var maxPayloadBytes: Int
    public var defaultTimeout: Duration
    public var generation: UInt64
    public var streamWindow: Int
    private var envelopeHandler: (@Sendable (ExtensionEnvelope) async -> Void)?
    private var openStreams: [String: Int] = [:]  // streamID → remaining credits

    public init(
        transport: any ExtensionWireTransport,
        maxPayloadBytes: Int = ExtensionHostLimits.default.maxPayloadBytes,
        maxFrameBytes: Int = ExtensionHostLimits.default.maxFrameBytes,
        defaultTimeout: Duration = .milliseconds(ExtensionHostLimits.default.requestTimeoutMS),
        generation: UInt64 = 0,
        streamWindow: Int = ExtensionHostLimits.default.streamWindow
    ) {
        self.transport = transport
        self.decoder = CBORFraming.Decoder(maxFrameBytes: maxFrameBytes)
        self.maxPayloadBytes = maxPayloadBytes
        self.defaultTimeout = defaultTimeout
        self.generation = generation
        self.streamWindow = streamWindow
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleChunk(chunk)
            }
            await self?.failAll(ExtensionWireError.transportClosed)
        }
    }

    public func setEnvelopeHandler(_ handler: @escaping @Sendable (ExtensionEnvelope) async -> Void) {
        envelopeHandler = handler
    }

    public func setGeneration(_ gen: UInt64) {
        generation = gen
    }

    public func send(_ envelope: ExtensionEnvelope) async throws {
        let body = try ExtensionEnvelopeCodec.encode(envelope)
        if body.count > maxPayloadBytes { throw ExtensionWireError.payloadTooLarge }
        let framed = try CBORFraming.encode(body, maxFrameBytes: decoder.maxFrameBytes)
        try await transport.send(framed)
    }

    public func request(
        _ method: ExtensionMethodID,
        payload: Data = Data(),
        timeout: Duration? = nil
    ) async throws -> Data {
        let id = ExtensionRequestID()
        let timeoutMS =
            Int((timeout ?? defaultTimeout).components.seconds * 1000)
            + Int((timeout ?? defaultTimeout).components.attoseconds / 1_000_000_000_000_000)
        let effectiveTimeout = timeout ?? defaultTimeout
        let req: ExtensionEnvelope = .request(
            id: id,
            method: method,
            payload: payload,
            timeoutMS: max(1, timeoutMS == 0 ? 15_000 : timeoutMS),
            generation: generation
        )
        if payload.count > maxPayloadBytes { throw ExtensionWireError.payloadTooLarge }

        let response: ExtensionEnvelope = try await withThrowingTaskGroup(of: ExtensionEnvelope.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExtensionEnvelope, Error>) in
                    Task {
                        await self.storePending(id: id.rawValue, cont: cont)
                        do {
                            try await self.send(req)
                        } catch {
                            await self.failPending(id: id.rawValue, error: error)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: effectiveTimeout)
                throw ExtensionWireError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if case .response(_, let result, let error, let gen) = response {
            if generation != 0 && gen != 0 && gen != generation {
                throw ExtensionWireError(code: -32009, message: "stale generation")
            }
            if let error { throw error }
            return result ?? Data()
        }
        throw ExtensionWireError(code: -32603, message: "unexpected response")
    }

    public func cancel(id: ExtensionRequestID) async {
        cancelled.insert(id.rawValue)
        inFlightTasks[id.rawValue]?.cancel()
        try? await send(.cancel(id: id))
        failPending(id: id.rawValue, error: ExtensionWireError.cancelled)
    }

    public func isCancelled(_ id: ExtensionRequestID) -> Bool {
        cancelled.contains(id.rawValue)
    }

    public func trackInFlight(id: ExtensionRequestID, task: Task<Void, Never>) {
        inFlightTasks[id.rawValue] = task
    }

    public func clearInFlight(id: ExtensionRequestID) {
        inFlightTasks[id.rawValue] = nil
    }

    public func openStream(id: ExtensionRequestID, streamID: String) async throws {
        openStreams[streamID] = streamWindow
        try await send(.streamOpen(id: id, streamID: streamID, window: streamWindow))
    }

    /// Sends a chunk if stream credits remain (backpressure).
    public func sendStreamChunk(streamID: String, sequence: UInt64, data: Data, fin: Bool) async throws {
        guard let credits = openStreams[streamID], credits > 0 else {
            throw ExtensionWireError(code: -32010, message: "stream backpressure")
        }
        openStreams[streamID] = credits - 1
        try await send(.streamChunk(streamID: streamID, sequence: sequence, data: data, fin: fin))
        if fin { openStreams[streamID] = nil }
    }

    public func creditStream(streamID: String, amount: Int = 1) {
        openStreams[streamID, default: 0] += amount
    }

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        failAll(ExtensionWireError.transportClosed)
        await transport.close()
    }

    // MARK: - Private

    private func handleChunk(_ chunk: Data) async {
        do {
            let frames = try decoder.append(chunk)
            for frame in frames {
                if frame.count > maxPayloadBytes {
                    await envelopeHandler?(.notification(kind: "error", payload: Data("payload too large".utf8)))
                    continue
                }
                let envelope = try ExtensionEnvelopeCodec.decode(frame)
                await dispatch(envelope)
            }
        } catch let error as ExtensionWireError {
            failAll(error)
            await transport.close()
        } catch {
            failAll(ExtensionWireError(code: -32700, message: String(describing: error)))
        }
    }

    private func dispatch(_ envelope: ExtensionEnvelope) async {
        switch envelope {
        case .response(let id, _, _, _):
            if let cont = pending.removeValue(forKey: id.rawValue) {
                cont.resume(returning: envelope)
            } else {
                await envelopeHandler?(envelope)
            }
        case .cancel(let id):
            cancelled.insert(id.rawValue)
            inFlightTasks[id.rawValue]?.cancel()
            await envelopeHandler?(envelope)
        case .streamChunk(let streamID, _, _, _):
            // Receiving chunk consumes peer window; credit on handler if needed
            creditStream(streamID: streamID, amount: 1)
            await envelopeHandler?(envelope)
        default:
            await envelopeHandler?(envelope)
        }
    }

    private func storePending(id: UUID, cont: CheckedContinuation<ExtensionEnvelope, Error>) {
        if closed {
            cont.resume(throwing: ExtensionWireError.transportClosed)
            return
        }
        pending[id] = cont
    }

    private func failPending(id: UUID, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: error)
        }
    }
}
