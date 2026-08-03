import CodeEditorWasmEngine
import Foundation

/// **Simulation / dual-run engine** — links a Swift ``LinkedWasmGuest`` factory.
///
/// EXT-N20: this type lives in ``CodeEditorWasmEngineTestSupport`` only — not a production product.
///
/// Module magic/size checks run, but **guest behavior is not determined by Wasm bytecode**.
/// Do **not** use this type as isolation evidence (audit §16 / Phase 9). Prefer ``WasmKitEngine``.
///
/// Note: protocol-based guest factory avoids a hard dependency cycle; Host constructs it.
public struct LinkedGuestWasmEngine: CodeEditorWasmEngine {
    public typealias GuestFactory = @Sendable () -> any LinkedWasmGuest

    private let factory: GuestFactory

    public init(factory: @escaping GuestFactory) {
        self.factory = factory
    }

    public func validate(module: Data, limits: WasmResourceLimits) throws {
        if module.count > limits.maxModuleBytes {
            throw WasmEngineError.moduleTooLarge(module.count)
        }
        guard module.count >= 8,
            module.starts(with: Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]))
        else {
            throw WasmEngineError.invalidModule("bad magic")
        }
        // Malformed marker used by fixtures
        if module.count >= 10, module[8] == 0xFF, module[9] == 0xFF {
            throw WasmEngineError.invalidModule("malformed")
        }
        // Missing export fixture: very small module without poll
        if module.count < 40 {
            throw WasmEngineError.missingExport(CoreWasmExport.poll.rawValue)
        }
    }

    public func instantiate(
        module: Data,
        imports: WasmHostImports,
        limits: WasmResourceLimits
    ) async throws -> any CodeEditorWasmInstance {
        try validate(module: module, limits: limits)
        // Simulation path may still use a Swift infinite-loop instance for dual-run stress;
        // isolation proof must use WasmKitEngine with real module bytes.
        if module == WasmModuleBuilder.infiniteLoopModule() {
            return InfiniteLoopInstance(limits: limits)
        }
        let guest = factory()
        guest.bindHost(imports: imports, limits: limits)
        return LinkedGuestWasmInstance(guest: guest, limits: limits)
    }
}

/// Honest simulation alias (Phase 9 / WASM-008) — **not** the real WasmKit backend.
public typealias CodeEditorWasmSimulationEngine = LinkedGuestWasmEngine

/// Minimal guest surface for linking without importing Protocol into every engine user.
public protocol LinkedWasmGuest: AnyObject, Sendable {
    func bindHost(imports: WasmHostImports, limits: WasmResourceLimits)
    func abiVersion() -> Int32
    func alloc(_ length: Int32) -> Int32
    func dealloc(_ ptr: Int32, _ length: Int32)
    func start(configPtr: Int32, configLen: Int32) -> Int32
    func receive(ptr: Int32, len: Int32) -> Int32
    func poll(_ budget: Int32) -> Int32
    func stop(_ reason: Int32)
    var memoryView: any WasmMemoryView { get }
}

public final class LinkedGuestWasmInstance: CodeEditorWasmInstance, @unchecked Sendable {
    public let guest: any LinkedWasmGuest
    private let limits: WasmResourceLimits
    private var _meters = WasmMeters()
    private let lock = NSLock()
    private var interrupted = false

    public init(guest: any LinkedWasmGuest, limits: WasmResourceLimits) {
        self.guest = guest
        self.limits = limits
    }

    public var memory: any WasmMemoryView { guest.memoryView }

    public var meters: WasmMeters {
        lock.lock()
        defer { lock.unlock() }
        return _meters
    }

    public var isInterrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interrupted
    }

    public func interrupt() {
        lock.lock()
        interrupted = true
        _meters.interrupted = true
        lock.unlock()
    }

    public func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
        if isInterrupted { throw WasmEngineError.interrupted }
        let ticks: Int = withLock {
            if name == CoreWasmExport.poll.rawValue { _meters.pollTicks += 1 }
            return _meters.pollTicks
        }
        if ticks > limits.maxPollTicks {
            interrupt()
            throw WasmEngineError.interrupted
        }
        switch name {
        case CoreWasmExport.abiVersion.rawValue:
            return [.i32(guest.abiVersion())]
        case CoreWasmExport.alloc.rawValue:
            return [.i32(guest.alloc(args[0].i32 ?? 0))]
        case CoreWasmExport.dealloc.rawValue:
            guest.dealloc(args[0].i32 ?? 0, args[1].i32 ?? 0)
            return []
        case CoreWasmExport.start.rawValue:
            return [.i32(guest.start(configPtr: args[0].i32 ?? 0, configLen: args[1].i32 ?? 0))]
        case CoreWasmExport.receive.rawValue:
            return [.i32(guest.receive(ptr: args[0].i32 ?? 0, len: args[1].i32 ?? 0))]
        case CoreWasmExport.poll.rawValue:
            let budget = min(Int(args[0].i32 ?? 0), limits.maxPollBudgetPerTick)
            withLock { _meters.budgetConsumed += budget }
            return [.i32(guest.poll(Int32(budget)))]
        case CoreWasmExport.stop.rawValue:
            guest.stop(args[0].i32 ?? 0)
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
}

final class InfiniteLoopInstance: CodeEditorWasmInstance, @unchecked Sendable {
    private let limits: WasmResourceLimits
    private var _meters = WasmMeters()
    private var interrupted = false
    private let mem = ByteMemory(size: 65536)
    init(limits: WasmResourceLimits) { self.limits = limits }
    var memory: any WasmMemoryView { mem }
    var meters: WasmMeters { _meters }
    var isInterrupted: Bool { interrupted }
    func interrupt() {
        interrupted = true
        _meters.interrupted = true
    }
    func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
        if interrupted { throw WasmEngineError.interrupted }
        switch name {
        case CoreWasmExport.abiVersion.rawValue: return [.i32(1)]
        case CoreWasmExport.alloc.rawValue: return [.i32(1024)]
        case CoreWasmExport.dealloc.rawValue: return []
        case CoreWasmExport.start.rawValue: return [.i32(0)]
        case CoreWasmExport.receive.rawValue: return [.i32(0)]
        case CoreWasmExport.poll.rawValue:
            _meters.pollTicks += 1
            if _meters.pollTicks > limits.maxPollTicks {
                interrupt()
                throw WasmEngineError.interrupted
            }
            // tight work
            var x = 0
            for i in 0..<50_000 { x &+= i }
            _ = x
            return [.i32(CoreWasmABI.statusBusy)]
        case CoreWasmExport.stop.rawValue: return []
        default: throw WasmEngineError.missingExport(name)
        }
    }
}

final class ByteMemory: WasmMemoryView, @unchecked Sendable {
    private var data: Data
    init(size: Int) { data = Data(count: size) }
    var size: Int { data.count }
    func read(offset: Int, length: Int) throws -> Data {
        guard offset >= 0, offset + length <= data.count else { throw WasmEngineError.trap("oob") }
        return data.subdata(in: offset..<(offset + length))
    }
    func write(offset: Int, data new: Data) throws {
        guard offset >= 0, offset + new.count <= data.count else { throw WasmEngineError.trap("oob") }
        data.replaceSubrange(offset..<(offset + new.count), with: new)
    }
    func grow(pages: Int) throws -> Int {
        let old = data.count / 65536
        let next = data.count + pages * 65536
        // Test support: cap at 16 MiB to avoid accidental OOM in dual-run.
        if next > 16 * 1024 * 1024 {
            throw WasmEngineError.memoryLimitExceeded
        }
        data.append(Data(count: pages * 65536))
        return old
    }
}
