import Foundation

/// Host or peer side JSON-RPC-like connection over framed envelopes.
public actor ExtensionRPCConnection {
    private let transport: any RemoteExtensionTransport
    private let decoder = ExtensionRPCFraming.Decoder()
    private var readerTask: Task<Void, Never>?
    private var pending: [UUID: CheckedContinuation<ExtensionRPCResponse, Error>] = [:]
    private var early: [UUID: ExtensionRPCResponse] = [:]
    private var closed = false
    public var maxPayloadBytes: Int
    public var defaultTimeout: Duration
    private var envelopeHandler: (@Sendable (ExtensionRPCEnvelope) async -> Void)?

    public init(
        transport: any RemoteExtensionTransport,
        maxPayloadBytes: Int = 4 * 1024 * 1024,
        defaultTimeout: Duration = .seconds(15)
    ) {
        self.transport = transport
        self.maxPayloadBytes = maxPayloadBytes
        self.defaultTimeout = defaultTimeout
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task { [weak self] in
            for await chunk in stream {
                await self?.handleChunk(chunk)
            }
            await self?.failAll(ExtensionHostError.transportClosed)
        }
    }

    public func setEnvelopeHandler(_ handler: @escaping @Sendable (ExtensionRPCEnvelope) async -> Void) {
        envelopeHandler = handler
    }

    public func send(_ envelope: ExtensionRPCEnvelope) async throws {
        let body = try ExtensionRPCCodec.encode(envelope)
        if body.count > maxPayloadBytes { throw ExtensionHostError.payloadTooLarge }
        try await transport.send(ExtensionRPCFraming.encode(body))
    }

    public func request(
        _ method: ExtensionRPCMethod,
        payload: Data = Data(),
        timeout: Duration? = nil
    ) async throws -> Data {
        let id = UUID()
        let timeoutMS = Int((timeout ?? defaultTimeout).components.seconds * 1000)
        let req = ExtensionRPCRequest(id: id, method: method, payload: payload, timeoutMS: max(1, timeoutMS))
        if req.payload.count > maxPayloadBytes { throw ExtensionHostError.payloadTooLarge }

        let effectiveTimeout = timeout ?? defaultTimeout
        let response: ExtensionRPCResponse = try await withThrowingTaskGroup(of: ExtensionRPCResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExtensionRPCResponse, Error>) in
                    Task {
                        await self.storePending(id: id, cont: cont)
                        do {
                            try await self.send(.request(req))
                        } catch {
                            await self.failPending(id: id, error: error)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: effectiveTimeout)
                throw ExtensionHostError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if let error = response.error {
            throw ExtensionHostError.rpc(error)
        }
        return response.result ?? Data()
    }

    public func close() async {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        await failAll(ExtensionHostError.transportClosed)
        await transport.close()
    }

    // MARK: - Private

    private func storePending(id: UUID, cont: CheckedContinuation<ExtensionRPCResponse, Error>) {
        if closed {
            cont.resume(throwing: ExtensionHostError.transportClosed)
            return
        }
        if let early = early.removeValue(forKey: id) {
            cont.resume(returning: early)
            return
        }
        pending[id] = cont
    }

    private func failPending(id: UUID, error: Error) {
        early.removeValue(forKey: id)
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        early.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: error)
        }
    }

    private func handleChunk(_ chunk: Data) async {
        let messages = decoder.append(chunk)
        for body in messages {
            if body.count > maxPayloadBytes {
                continue
            }
            guard let envelope = try? ExtensionRPCCodec.decode(body) else { continue }
            await handleEnvelope(envelope)
        }
    }

    private func handleEnvelope(_ envelope: ExtensionRPCEnvelope) async {
        switch envelope {
        case .response(let response):
            if let cont = pending.removeValue(forKey: response.id) {
                cont.resume(returning: response)
            } else {
                early[response.id] = response
            }
        default:
            await envelopeHandler?(envelope)
        }
    }
}
