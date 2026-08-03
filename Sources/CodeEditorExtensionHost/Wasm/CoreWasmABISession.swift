import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensionWasmGuest
import CodeEditorWasmEngine
import Foundation

/// Host-side core-Wasm ABI v1 session: start/receive/poll/stop with CBOR envelopes.
///
/// Hardened for WASM-N08…N14:
/// - Per-request / per-activation deadlines (monotonic), not session lifetime
/// - ``OneShotPromise`` pending registration before work starts
/// - Request-keyed cancellation (not sticky global hasCancel)
/// - Enforced concurrent/alloc/log/queue/byte quotas
/// - Bounded log ring with truncation metrics
/// - Poll status validation
/// - Guest alloc/dealloc pairing via defer
public actor CoreWasmABISession {
    public let limits: WasmResourceLimits
    public let generation: UInt64

    private let engine: any CodeEditorWasmEngine
    private let module: Data
    private var instance: (any CodeEditorWasmInstance)?
    private var pending: [UUID: OneShotPromise<Data>] = [:]
    private var started = false
    private let tracer = ConformanceTracer()
    /// Activation deadline (monotonic). Optional; nil means no activation-wide cap beyond per-request.
    private var activationDeadline: ContinuousClock.Instant?
    private var cancelIDs: Set<UUID> = []
    private var activeRequestCount = 0
    private var outstandingAllocs = 0
    private var activationPollTicks = 0
    private var slowWorkInjector: ((Int) -> Void)?
    private var messageBox: MessageBox?

    public init(
        engine: any CodeEditorWasmEngine,
        module: Data,
        limits: WasmResourceLimits = .default,
        generation: UInt64 = 1,
        slowWorkInjector: ((Int) -> Void)? = nil
    ) {
        self.engine = engine
        self.module = module
        self.limits = limits
        self.generation = generation
        self.slowWorkInjector = slowWorkInjector
    }

    public func start() async throws {
        let box = MessageBox(limits: limits)
        self.messageBox = box

        let imports = WasmHostImports(
            send: { [limits] ptr, len in
                if len < 0 { return CoreWasmABI.statusError }
                if len == 0 { return box.enqueue(Data()) }
                guard let ptr else { return CoreWasmABI.statusError }
                if Int(len) > limits.maxResponseBytes {
                    return CoreWasmABI.statusBackpressure
                }
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
                WasmMonotonicClock.nowMillis()
            },
            shouldCancel: { high, low in
                box.isCancelled(high: high, low: low) ? 1 : 0
            }
        )

        let inst = try await engine.instantiate(module: module, imports: imports, limits: limits)
        instance = inst

        // Per-activation start budget only (WASM-N08) — not a sticky session-wide wall clock.
        let startDeadline = ContinuousClock.now + limits.maxWallTime
        activationDeadline = nil

        let config = CBORCodec.encode(
            CBORValue.stringMap([
                "schema": .text(ExtensionMethodCatalog.schemaHash),
                "generation": .unsigned(generation),
                "abi": .int(Int(CoreWasmABI.version)),
            ]))
        if config.count > limits.maxRequestBytes {
            throw WasmEngineError.requestTooLarge(config.count)
        }

        let ptr = try await allocGuest(Int32(config.count))
        let st: Int32
        do {
            if ContinuousClock.now > startDeadline {
                throw WasmEngineError.deadlineExceeded
            }
            try inst.memory.write(offset: Int(ptr), data: config)
            st = try await callI32(CoreWasmExport.start.rawValue, [.i32(ptr), .i32(Int32(config.count))])
        } catch {
            await safeDealloc(ptr, Int32(config.count))
            throw error
        }
        await safeDealloc(ptr, Int32(config.count))
        guard st == CoreWasmABI.statusOK else {
            throw WasmEngineError.trap("start failed status=\(st)")
        }
        started = true
        tracer.record(method: .activate, direction: "host→wasm", payload: config, generation: generation)
    }

    public func request(
        _ method: ExtensionMethodID,
        payload: Data = Data(),
        timeout: Duration = .seconds(2)
    ) async throws -> Data {
        guard started else { throw WasmEngineError.trap("not started") }
        if payload.count > limits.maxRequestBytes {
            throw WasmEngineError.requestTooLarge(payload.count)
        }
        if activeRequestCount >= limits.maxConcurrentRequests {
            throw WasmEngineError.resourceLimit("maxConcurrentRequests")
        }

        let id = ExtensionRequestID()
        let env = ExtensionEnvelope.request(
            id: id,
            method: method,
            payload: payload,
            timeoutMS: max(1, Int(Self.seconds(timeout) * 1000)),
            generation: generation
        )
        let bytes = try ExtensionEnvelopeCodec.encode(env)
        if bytes.count > limits.maxRequestBytes {
            throw WasmEngineError.requestTooLarge(bytes.count)
        }
        tracer.record(method: method, direction: "host→wasm", payload: payload, generation: generation)

        // WASM-N09: register OneShotPromise BEFORE any async work.
        let promise = OneShotPromise<Data>()
        pending[id.rawValue] = promise
        activeRequestCount += 1
        let (high, low) = Self.splitUUID(id.rawValue)
        messageBox?.setActiveRequest(high: high, low: low)

        defer {
            pending[id.rawValue] = nil
            activeRequestCount = max(0, activeRequestCount - 1)
            messageBox?.clearActiveRequest()
            messageBox?.clearCancel(high: high, low: low)
            cancelIDs.remove(id.rawValue)
        }

        do {
            try await pushReceive(bytes)
            let deadline = ContinuousClock.now + timeout
            var requestPollTicks = 0
            while ContinuousClock.now < deadline {
                if let done = promise.resultIfCompleted {
                    let data = try done.get()
                    if data.count > limits.maxResponseBytes {
                        throw WasmEngineError.responseTooLarge(data.count)
                    }
                    tracer.record(method: method, direction: "wasm→host", payload: data, generation: generation)
                    return data
                }
                if cancelIDs.contains(id.rawValue) {
                    promise.fail(ExtensionWireError.cancelled)
                    throw ExtensionWireError.cancelled
                }
                try await pollOnce(forRequest: id.rawValue)
                requestPollTicks += 1
                if requestPollTicks > limits.maxPollTicksPerRequest {
                    promise.fail(WasmEngineError.resourceLimit("maxPollTicksPerRequest"))
                    throw WasmEngineError.resourceLimit("maxPollTicksPerRequest")
                }
                if promise.isCompleted { continue }
                try await Task.sleep(for: .milliseconds(1))
            }
            if let done = promise.resultIfCompleted {
                let data = try done.get()
                tracer.record(method: method, direction: "wasm→host", payload: data, generation: generation)
                return data
            }
            promise.fail(ExtensionWireError.timeout)
            throw ExtensionWireError.timeout
        } catch {
            _ = promise.fail(error)
            throw error
        }
    }

    public func cancel(_ id: ExtensionRequestID) async {
        cancelIDs.insert(id.rawValue)
        let (high, low) = Self.splitUUID(id.rawValue)
        messageBox?.flagCancel(high: high, low: low)
        if let bytes = try? ExtensionEnvelopeCodec.encode(.cancel(id: id)) {
            try? await pushReceive(bytes)
        }
        try? await pollOnce(forRequest: id.rawValue)
        if let p = pending[id.rawValue] {
            p.fail(ExtensionWireError.cancelled)
        }
    }

    public func stop() async {
        _ = try? await callI32(CoreWasmExport.stop.rawValue, [.i32(0)])
        instance?.interrupt()
        instance = nil
        started = false
        for (_, p) in pending {
            p.fail(ExtensionWireError.transportClosed)
        }
        pending.removeAll()
        cancelIDs.removeAll()
        activeRequestCount = 0
        outstandingAllocs = 0
    }

    public func conformanceTrace() -> [ConformanceEvent] { tracer.snapshot() }

    public func setSlowWork(_ n: Int) {
        slowWorkInjector?(n)
    }

    public func pollOnce() async throws {
        try await pollOnce(forRequest: nil)
    }

    public func pollOnce(forRequest requestID: UUID?) async throws {
        _ = requestID
        // WASM-N08: no session-wide wall deadline — only per-request budgets in request().
        if instance?.isInterrupted == true {
            throw WasmEngineError.interrupted
        }
        activationPollTicks += 1
        if activationPollTicks > limits.maxPollTicks {
            instance?.interrupt()
            throw WasmEngineError.resourceLimit("maxPollTicks")
        }

        let raw = try await callI32(
            CoreWasmExport.poll.rawValue,
            [.i32(Int32(limits.maxPollBudgetPerTick))]
        )
        // WASM-N13: enforce known poll statuses.
        _ = try CoreWasmPollStatus.parse(raw)

        while let msg = messageBox?.dequeue() {
            try handleGuestMessage(msg)
        }
    }

    private func handleGuestMessage(_ data: Data) throws {
        if data.count > limits.maxResponseBytes {
            throw WasmEngineError.responseTooLarge(data.count)
        }
        let env = try ExtensionEnvelopeCodec.decode(data)
        switch env {
        case .response(let id, let result, let error, _):
            if let promise = pending[id.rawValue] {
                if let error {
                    promise.fail(error)
                } else {
                    promise.succeed(result ?? Data())
                }
            }
        default:
            break
        }
    }

    private func pushReceive(_ data: Data) async throws {
        guard let instance else { throw WasmEngineError.trap("no instance") }
        let ptr = try await allocGuest(Int32(data.count))
        let st: Int32
        do {
            try instance.memory.write(offset: Int(ptr), data: data)
            st = try await callI32(CoreWasmExport.receive.rawValue, [.i32(ptr), .i32(Int32(data.count))])
        } catch {
            await safeDealloc(ptr, Int32(data.count))
            throw error
        }
        await safeDealloc(ptr, Int32(data.count))
        guard st == CoreWasmABI.statusOK else { throw WasmEngineError.trap("receive \(st)") }
    }

    private func allocGuest(_ length: Int32) async throws -> Int32 {
        if outstandingAllocs >= limits.maxOutstandingGuestAllocations {
            throw WasmEngineError.allocationLimitExceeded
        }
        let ptr = try await callI32(CoreWasmExport.alloc.rawValue, [.i32(length)])
        guard ptr != 0 else { throw WasmEngineError.trap("alloc failed") }
        outstandingAllocs += 1
        return ptr
    }

    private func safeDealloc(_ ptr: Int32, _ length: Int32) async {
        // WASM-N14: pair every alloc with dealloc, including failures.
        do {
            _ = try await callI32(CoreWasmExport.dealloc.rawValue, [.i32(ptr), .i32(length)])
            outstandingAllocs = max(0, outstandingAllocs - 1)
        } catch {
            outstandingAllocs = max(0, outstandingAllocs - 1)
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

    private static func splitUUID(_ id: UUID) -> (Int64, Int64) {
        let u = id.uuid
        let high = Int64(bitPattern:
            (UInt64(u.0) << 56) | (UInt64(u.1) << 48) | (UInt64(u.2) << 40) | (UInt64(u.3) << 32)
                | (UInt64(u.4) << 24) | (UInt64(u.5) << 16) | (UInt64(u.6) << 8) | UInt64(u.7))
        let low = Int64(bitPattern:
            (UInt64(u.8) << 56) | (UInt64(u.9) << 48) | (UInt64(u.10) << 40) | (UInt64(u.11) << 32)
                | (UInt64(u.12) << 24) | (UInt64(u.13) << 16) | (UInt64(u.14) << 8) | UInt64(u.15))
        return (high, low)
    }
}

// MARK: - Message box (bounded logs + keyed cancel)

final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var bytes = 0
    private let limits: WasmResourceLimits
    private var cancelledKeys: Set<String> = []
    private var activeHigh: Int64 = 0
    private var activeLow: Int64 = 0
    private var logRing: [String] = []
    private var logBytes = 0
    private var logTruncations = 0
    private var logWindowStart = ContinuousClock.now
    private var logBytesInWindow = 0

    /// Test/compat: true if any cancel currently flagged.
    var hasCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelledKeys.isEmpty
    }

    var logTruncationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return logTruncations
    }

    var retainedLogBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return logBytes
    }

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

    func flagCancel(high: Int64 = 0, low: Int64 = 0) {
        lock.lock()
        cancelledKeys.insert("\(high):\(low)")
        // Also flag active request if present
        if activeHigh != 0 || activeLow != 0 {
            cancelledKeys.insert("\(activeHigh):\(activeLow)")
        }
        lock.unlock()
    }

    /// Legacy global flag path used by older tests — maps to zero key.
    func flagCancel() {
        flagCancel(high: 0, low: 0)
    }

    func clearCancel(high: Int64, low: Int64) {
        lock.lock()
        cancelledKeys.remove("\(high):\(low)")
        lock.unlock()
    }

    func setActiveRequest(high: Int64, low: Int64) {
        lock.lock()
        activeHigh = high
        activeLow = low
        lock.unlock()
    }

    func clearActiveRequest() {
        lock.lock()
        activeHigh = 0
        activeLow = 0
        lock.unlock()
    }

    func isCancelled(high: Int64, low: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelledKeys.contains("\(high):\(low)") { return true }
        if (activeHigh != 0 || activeLow != 0),
            high == activeHigh, low == activeLow,
            cancelledKeys.contains("\(activeHigh):\(activeLow)")
        {
            return true
        }
        // Zero-key global only when explicitly flagged as (0,0)
        if high == 0, low == 0, cancelledKeys.contains("0:0") { return true }
        return false
    }

    func log(_ s: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if now - logWindowStart >= .seconds(1) {
            logWindowStart = now
            logBytesInWindow = 0
        }
        let payload = s.utf8.count
        if logBytesInWindow + payload > limits.maxLogBytesPerSecond {
            logTruncations += 1
            return
        }
        logBytesInWindow += payload
        // Byte-counted ring (WASM-N11)
        logRing.append(s)
        logBytes += payload
        while logBytes > limits.maxLogBytes || logRing.count > limits.maxLogMessages {
            if logRing.isEmpty { break }
            let dropped = logRing.removeFirst()
            logBytes -= dropped.utf8.count
            logTruncations += 1
        }
    }
}

