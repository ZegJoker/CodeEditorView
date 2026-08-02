import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorWasmEngine
import Foundation

/// Host-side core-Wasm ABI v1 session: start/receive/poll/stop with CBOR envelopes.
public actor CoreWasmABISession {
    public let limits: WasmResourceLimits
    public let generation: UInt64

    private let engine: any CodeEditorWasmEngine
    private let module: Data
    private var instance: (any CodeEditorWasmInstance)?
    private var linked: WasmGuestLink?
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var started = false
    private let tracer = ConformanceTracer()
    private let deadline: Date
    private var cancelIDs: Set<UUID> = []

    public init(
        engine: any CodeEditorWasmEngine,
        module: Data,
        limits: WasmResourceLimits = .default,
        generation: UInt64 = 1
    ) {
        self.engine = engine
        self.module = module
        self.limits = limits
        self.generation = generation
        self.deadline = Date().addingTimeInterval(Self.seconds(limits.maxWallTime))
    }

    public func start() async throws {
        let box = MessageBox(limits: limits)
        let imports = WasmHostImports(
            send: { ptr, len in
                if len < 0 { return CoreWasmABI.statusError }
                if len == 0 { return box.enqueue(Data()) }
                guard let ptr else { return CoreWasmABI.statusError }
                let data = Data(bytes: ptr, count: Int(len))
                return box.enqueue(data)
            },
            log: { level, ptr, len in
                _ = level
                if let ptr, len > 0 {
                    let s = String(bytes: Data(bytes: ptr, count: Int(len)), encoding: .utf8) ?? ""
                    box.log(s)
                }
            },
            monotonicMillis: {
                Int64(Date().timeIntervalSince1970 * 1000)
            },
            shouldCancel: { [weak box] _, _ in
                // Session sets cancels via box
                box?.hasCancel == true ? 1 : 0
            }
        )

        // Capture box for cancel updates
        self.messageBox = box

        let inst = try await engine.instantiate(module: module, imports: imports, limits: limits)
        instance = inst
        if let lg = inst as? LinkedGuestWasmInstance, let link = lg.guest as? WasmGuestLink {
            linked = link
        }

        let config = CBORCodec.encode(
            CBORValue.stringMap([
                "schema": .text(ExtensionMethodCatalog.schemaHash),
                "generation": .unsigned(generation),
                "abi": .int(Int(CoreWasmABI.version)),
            ]))
        let ptr = try await callI32(CoreWasmExport.alloc.rawValue, [.i32(Int32(config.count))])
        guard ptr != 0 else { throw WasmEngineError.trap("alloc failed") }
        try inst.memory.write(offset: Int(ptr), data: config)
        let st = try await callI32(CoreWasmExport.start.rawValue, [.i32(ptr), .i32(Int32(config.count))])
        guard st == CoreWasmABI.statusOK else {
            throw WasmEngineError.trap("start failed status=\(st)")
        }
        started = true
        tracer.record(method: .activate, direction: "host→wasm", payload: config, generation: generation)
    }

    private var messageBox: MessageBox?

    public func request(
        _ method: ExtensionMethodID,
        payload: Data = Data(),
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        guard started else { throw WasmEngineError.trap("not started") }
        let id = ExtensionRequestID()
        let env = ExtensionEnvelope.request(
            id: id,
            method: method,
            payload: payload,
            timeoutMS: max(1, Int(Self.seconds(timeout) * 1000)),
            generation: generation
        )
        let bytes = try ExtensionEnvelopeCodec.encode(env)
        tracer.record(method: method, direction: "host→wasm", payload: payload, generation: generation)

        let result: Data = try await withCheckedThrowingContinuation { cont in
            Task {
                await self.runRequest(id: id.rawValue, bytes: bytes, timeout: timeout, cont: cont)
            }
        }
        tracer.record(method: method, direction: "wasm→host", payload: result, generation: generation)
        return result
    }

    private func runRequest(
        id: UUID,
        bytes: Data,
        timeout: Duration,
        cont: CheckedContinuation<Data, Error>
    ) async {
        pending[id] = cont
        do {
            try await pushReceive(bytes)
            let deadline = Date().addingTimeInterval(Self.seconds(timeout))
            while Date() < deadline {
                if pending[id] == nil { return }  // resumed from handleGuestMessage
                try await pollOnce()
                if pending[id] == nil { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            failPending(id, ExtensionWireError.timeout)
        } catch {
            failPending(id, error)
        }
    }

    public func cancel(_ id: ExtensionRequestID) async {
        cancelIDs.insert(id.rawValue)
        messageBox?.flagCancel()
        if let bytes = try? ExtensionEnvelopeCodec.encode(.cancel(id: id)) {
            try? await pushReceive(bytes)
        }
        try? await pollOnce()
    }

    public func stop() async {
        _ = try? await callI32(CoreWasmExport.stop.rawValue, [.i32(0)])
        instance?.interrupt()
        instance = nil
        linked = nil
        started = false
        for (_, c) in pending { c.resume(throwing: ExtensionWireError.transportClosed) }
        pending.removeAll()
    }

    public func conformanceTrace() -> [ConformanceEvent] { tracer.snapshot() }

    public func setSlowWork(_ n: Int) {
        linked?.runtime.pendingSlowWork = n
    }

    public func pollOnce() async throws {
        if Date() > deadline {
            instance?.interrupt()
            throw WasmEngineError.deadlineExceeded
        }
        if instance?.isInterrupted == true {
            throw WasmEngineError.interrupted
        }
        _ = try await callI32(
            CoreWasmExport.poll.rawValue,
            [.i32(Int32(limits.maxPollBudgetPerTick))]
        )
        while let msg = messageBox?.dequeue() {
            try handleGuestMessage(msg)
        }
    }

    private func handleGuestMessage(_ data: Data) throws {
        let env = try ExtensionEnvelopeCodec.decode(data)
        switch env {
        case .response(let id, let result, let error, _):
            if let cont = pending.removeValue(forKey: id.rawValue) {
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: result ?? Data()) }
            }
        default:
            break
        }
    }

    private func pushReceive(_ data: Data) async throws {
        guard let instance else { throw WasmEngineError.trap("no instance") }
        let ptr = try await callI32(CoreWasmExport.alloc.rawValue, [.i32(Int32(data.count))])
        try instance.memory.write(offset: Int(ptr), data: data)
        let st = try await callI32(CoreWasmExport.receive.rawValue, [.i32(ptr), .i32(Int32(data.count))])
        guard st == CoreWasmABI.statusOK else { throw WasmEngineError.trap("receive \(st)") }
    }

    private func storePending(_ id: UUID, _ cont: CheckedContinuation<Data, Error>) {
        pending[id] = cont
    }

    private func failPending(_ id: UUID, _ error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func callI32(_ name: String, _ args: [WasmValue]) async throws -> Int32 {
        guard let instance else { throw WasmEngineError.trap("no instance") }
        let result = try await instance.call(name, args: args)
        guard let v = result.first?.i32 else { throw WasmEngineError.trap("bad ret \(name)") }
        return v
    }

    private static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}

final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var bytes = 0
    private let limits: WasmResourceLimits
    private(set) var hasCancel = false
    private var logs: [String] = []

    init(limits: WasmResourceLimits) { self.limits = limits }

    func enqueue(_ data: Data) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if queue.count >= limits.maxHostSendQueueMessages || bytes + data.count > limits.maxHostSendQueueBytes {
            return CoreWasmABI.statusBackpressure
        }
        queue.append(data)
        bytes += data.count
        return CoreWasmABI.statusOK
    }

    func dequeue() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        let d = queue.removeFirst()
        bytes -= d.count
        return d
    }

    func flagCancel() {
        lock.lock()
        hasCancel = true
        lock.unlock()
    }

    func log(_ s: String) {
        lock.lock()
        logs.append(s)
        lock.unlock()
    }
}
