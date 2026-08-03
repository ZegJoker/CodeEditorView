import CodeEditorWasmEngine
import Foundation

/// Engine that runs ``WasmGuestRuntime``-compatible ABI logic in-process.
///
/// **Test support only** (WASM-N15 residual): not isolation evidence and not a production
/// default. Lives in ``CodeEditorWasmEngineTestSupport``; WasmKit is the production path.
///
/// Module bytes must start with `\0asm` and pass size limits; content is treated as a
/// capability token (conformance / malicious markers) selecting guest behavior.
public struct InProcessCoreWasmEngine: CodeEditorWasmEngine {
    public init() {}

    public func validate(module: Data, limits: WasmResourceLimits) throws {
        if module.count > limits.maxModuleBytes {
            throw WasmEngineError.moduleTooLarge(module.count)
        }
        guard module.count >= 8 else { throw WasmEngineError.invalidModule("too short") }
        guard module.starts(with: Data(WasmModuleBuilder.magic + WasmModuleBuilder.version)) else {
            throw WasmEngineError.invalidModule("bad magic")
        }
        if module.count == 10 && module[8] == 0xFF {
            throw WasmEngineError.invalidModule("malformed")
        }
    }

    public func instantiate(
        module: Data,
        imports: WasmHostImports,
        limits: WasmResourceLimits
    ) async throws -> any CodeEditorWasmInstance {
        try validate(module: module, limits: limits)
        // Marker-based behavior from builder fixtures
        let kind: GuestKind
        if module == WasmModuleBuilder.infiniteLoopModule() {
            kind = .infiniteLoop
        } else if module == WasmModuleBuilder.missingExportModule()
            || module == WasmModuleBuilder.abiVersionOnlyModule()
        {
            throw WasmEngineError.missingExport(CoreWasmExport.poll.rawValue)
        } else if module == WasmModuleBuilder.malformedModule() {
            throw WasmEngineError.invalidModule("malformed")
        } else {
            kind = .conformance
        }
        return InProcessWasmInstance(imports: imports, limits: limits, kind: kind)
    }

    enum GuestKind {
        case conformance
        case infiniteLoop
    }
}

final class InProcessWasmInstance: CodeEditorWasmInstance, @unchecked Sendable {
    private let imports: WasmHostImports
    private let limits: WasmResourceLimits
    private let kind: InProcessCoreWasmEngine.GuestKind
    private let guest = WasmGuestBridge()
    private let lock = NSLock()
    private var _meters = WasmMeters()
    private var interrupted = false
    private var memoryView: InProcessMemory

    init(imports: WasmHostImports, limits: WasmResourceLimits, kind: InProcessCoreWasmEngine.GuestKind) {
        self.imports = imports
        self.limits = limits
        self.kind = kind
        self.memoryView = InProcessMemory(
            size: min(limits.maxLinearMemoryBytes, 256 * 1024),
            maxBytes: limits.maxLinearMemoryBytes
        )
        guest.attach(memory: memoryView, imports: imports)
    }

    var memory: any WasmMemoryView { memoryView }

    var meters: WasmMeters {
        lock.lock()
        defer { lock.unlock() }
        return _meters
    }

    var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    func interrupt() {
        lock.lock()
        interrupted = true
        _meters.interrupted = true
        lock.unlock()
    }

    func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
        if isInterrupted { throw WasmEngineError.interrupted }
        let elapsedNanos = WasmMonotonicClock.nowNanos() - meters.wallTimeStartedNanos
        let limitNanos = durationNanos(limits.maxWallTime)
        if elapsedNanos > limitNanos {
            interrupt()
            throw WasmEngineError.deadlineExceeded
        }
        switch name {
        case CoreWasmExport.abiVersion.rawValue:
            return [.i32(guest.abiVersion())]
        case CoreWasmExport.alloc.rawValue:
            let len = args.first?.i32 ?? 0
            return [.i32(guest.alloc(len))]
        case CoreWasmExport.dealloc.rawValue:
            guest.dealloc(args[0].i32 ?? 0, args[1].i32 ?? 0)
            return []
        case CoreWasmExport.start.rawValue:
            return [.i32(guest.start(args[0].i32 ?? 0, args[1].i32 ?? 0))]
        case CoreWasmExport.receive.rawValue:
            return [.i32(guest.receive(args[0].i32 ?? 0, args[1].i32 ?? 0))]
        case CoreWasmExport.poll.rawValue:
            if kind == .infiniteLoop {
                let ticks = withLock {
                    _meters.pollTicks += 1
                    return _meters.pollTicks
                }
                if ticks > limits.maxPollTicks {
                    interrupt()
                    throw WasmEngineError.interrupted
                }
                var x = 0
                for i in 0..<10_000 { x &+= i }
                _ = x
                return [.i32(CoreWasmABI.statusBusy)]
            }
            let budget = min(Int(args.first?.i32 ?? 0), limits.maxPollBudgetPerTick)
            withLock {
                _meters.pollTicks += 1
                _meters.budgetConsumed += budget
            }
            let status = guest.poll(Int32(budget))
            return [.i32(status)]
        case CoreWasmExport.stop.rawValue:
            guest.stop(args.first?.i32 ?? 0)
            return []
        default:
            throw WasmEngineError.missingExport(name)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func durationNanos(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
    }
}

final class InProcessMemory: WasmMemoryView, @unchecked Sendable {
    private var storage: Data
    private let lock = NSLock()
    private let maxBytes: Int
    init(size: Int, maxBytes: Int = 16 * 1024 * 1024) {
        self.storage = Data(count: max(65536, size))
        self.maxBytes = maxBytes
    }
    var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
    func read(offset: Int, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard offset >= 0, length >= 0, offset + length <= storage.count else {
            throw WasmEngineError.trap("oob read")
        }
        return storage.subdata(in: offset..<(offset + length))
    }
    func write(offset: Int, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard offset >= 0, offset + data.count <= storage.count else {
            throw WasmEngineError.trap("oob write")
        }
        storage.replaceSubrange(offset..<(offset + data.count), with: data)
    }
    func grow(pages: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let old = storage.count / 65536
        let next = storage.count + pages * 65536
        if next > maxBytes {
            throw WasmEngineError.memoryLimitExceeded
        }
        storage.append(Data(count: pages * 65536))
        return old
    }
}

/// Bridges host imports without depending on WasmGuest module (engine stays free of Protocol).
final class WasmGuestBridge: @unchecked Sendable {
    private var memory: InProcessMemory?
    private var imports: WasmHostImports?
    private var heap = 2048
    private var started = false
    private var stopped = false
    private var schemaOK = true
    private var inbound: [Data] = []
    private var outbox: [Data] = []
    private var generation: UInt64 = 0
    private var slowWork = 0

    func attach(memory: InProcessMemory, imports: WasmHostImports) {
        self.memory = memory
        self.imports = imports
    }

    func abiVersion() -> Int32 { 1 }

    func alloc(_ length: Int32) -> Int32 {
        let len = Int(length)
        let p = heap
        heap += max(0, len)
        return Int32(p)
    }

    func dealloc(_ p: Int32, _ l: Int32) {
        _ = p
        _ = l
    }

    func start(_ ptr: Int32, _ len: Int32) -> Int32 {
        guard let memory, let data = try? memory.read(offset: Int(ptr), length: Int(len)) else {
            return 1
        }
        // Accept empty config or any bytes containing schema marker check at host layer.
        // Host writes config; if starts with error marker 0xFF fail
        if data.first == 0xFF { return 1 }
        // Parse generation lightly: look for UTF-8 "generation" not required
        started = true
        generation = 1
        return 0
    }

    func receive(_ ptr: Int32, _ len: Int32) -> Int32 {
        guard started, !stopped, let memory,
            let data = try? memory.read(offset: Int(ptr), length: Int(len))
        else { return 1 }
        inbound.append(data)
        return 0
    }

    func poll(_ budget: Int32) -> Int32 {
        guard started, !stopped else { return 1 }
        var budget = Int(budget)
        // Process one inbound as echo/request using host_send of same bytes wrapped if possible
        while budget > 0, !inbound.isEmpty {
            let msg = inbound.removeFirst()
            budget -= 1
            // If host_send backpressure
            let rc = sendToHost(msg)
            if rc != 0 { return 4 }
        }
        while budget > 0, slowWork > 0 {
            if imports?.shouldCancel(0, Int64(slowWork)) != 0 {
                slowWork = 0
                return 3
            }
            slowWork -= 1
            budget -= 1
        }
        return (inbound.isEmpty && slowWork == 0) ? 0 : 2
    }

    func stop(_ reason: Int32) {
        stopped = true
        inbound.removeAll()
        _ = reason
    }

    func enqueueSlowWork(_ n: Int) { slowWork = n }

    private func sendToHost(_ data: Data) -> Int32 {
        guard let imports else { return 1 }
        return data.withUnsafeBytes { raw -> Int32 in
            let base = raw.baseAddress
            return imports.send(base, Int32(data.count))
        }
    }
}
