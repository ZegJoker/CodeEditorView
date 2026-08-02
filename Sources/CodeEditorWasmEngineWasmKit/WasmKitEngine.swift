import CodeEditorWasmEngine
import Foundation
import os

#if canImport(WasmKit)
    import WasmKit
    import WasmTypes
#endif

/// **Real WasmKit-backed engine** — submitted module bytes determine executed behavior.
///
/// ## Phase 9 / WASM-001…005
/// - `parseWasm(bytes:)` validates structure
/// - Fresh `Store` per instance; only `codeeditor` host imports
/// - Host imports read **guest linear memory** (ptr/len) with OOB-safe bounds
/// - Wall-time watchdog on `call` + cooperative `host_should_cancel` / `interrupt()`
/// - Enforces module size and max linear memory
public struct WasmKitEngine: CodeEditorWasmEngine {
    public init() {}

    /// Factory argument is **ignored** — real execution uses module bytes only.
    public init(guestFactory: @escaping () -> Any) {
        self.init()
        _ = guestFactory
    }

    public static func withDefaultGuestFactory(
        _ factory: @escaping () -> Any
    ) -> WasmKitEngine {
        WasmKitEngine(guestFactory: factory)
    }

    public func validate(module: Data, limits: WasmResourceLimits) throws {
        guard module.count <= limits.maxModuleBytes else {
            throw WasmEngineError.moduleTooLarge(module.count)
        }
        guard module.count >= 8 else {
            throw WasmEngineError.invalidModule("module too short")
        }
        #if canImport(WasmKit)
            do {
                _ = try parseWasm(bytes: Array(module))
            } catch {
                throw WasmEngineError.invalidModule(String(describing: error))
            }
        #else
            throw WasmEngineError.invalidModule("WasmKit not linked")
        #endif
    }

    public func instantiate(
        module: Data,
        imports: WasmHostImports,
        limits: WasmResourceLimits
    ) async throws -> any CodeEditorWasmInstance {
        try validate(module: module, limits: limits)
        #if canImport(WasmKit)
            return try await WasmKitInstance.create(moduleBytes: module, host: imports, limits: limits)
        #else
            throw WasmEngineError.invalidModule("WasmKit not linked")
        #endif
    }
}

#if canImport(WasmKit)

    // MARK: - Memory holder for host import closures

    /// Filled after instantiate so import callbacks can read guest linear memory (WASM-003).
    final class GuestMemoryHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _memory: Memory?
        private var _interrupted = false
        private var _cancel: (() -> Int32)?

        func setMemory(_ memory: Memory) {
            lock.lock()
            _memory = memory
            lock.unlock()
        }

        func setCancelCheck(_ check: @escaping () -> Int32) {
            lock.lock()
            _cancel = check
            lock.unlock()
        }

        func interrupt() {
            lock.lock()
            _interrupted = true
            lock.unlock()
        }

        var isInterrupted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _interrupted
        }

        func read(offset: Int, length: Int) throws -> Data {
            lock.lock()
            let memory = _memory
            lock.unlock()
            guard let memory else {
                throw WasmEngineError.trap("guest memory not bound")
            }
            let total = memory.data.count
            guard offset >= 0, length >= 0,
                offset <= total,
                length <= total - offset
            else {
                throw WasmEngineError.trap("memory oob read offset=\(offset) len=\(length) size=\(total)")
            }
            if length == 0 { return Data() }
            return try memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                Data(buf)
            }
        }

        func shouldCancel(a: Int64, b: Int64, host: WasmHostImports) -> Int32 {
            if isInterrupted { return 1 }
            lock.lock()
            let custom = _cancel
            lock.unlock()
            if let custom { return custom() }
            return host.shouldCancel(a, b)
        }
    }

    // MARK: - Instance

    final class WasmKitInstance: CodeEditorWasmInstance, @unchecked Sendable {
        private let engine: Engine
        private let store: Store
        private let instance: Instance
        private let memoryView: WasmKitMemoryView
        private let limits: WasmResourceLimits
        private let memoryHolder: GuestMemoryHolder
        private let state = OSAllocatedUnfairLock(initialState: (interrupted: false, meters: WasmMeters()))

        var memory: any WasmMemoryView { memoryView }
        var meters: WasmMeters {
            state.withLock { $0.meters }
        }
        var isInterrupted: Bool {
            state.withLock { $0.interrupted } || memoryHolder.isInterrupted
        }

        static func create(
            moduleBytes: Data,
            host: WasmHostImports,
            limits: WasmResourceLimits
        ) async throws -> WasmKitInstance {
            let module: Module
            do {
                module = try parseWasm(bytes: Array(moduleBytes))
            } catch {
                throw WasmEngineError.invalidModule(String(describing: error))
            }

            let engine = Engine()
            let store = Store(engine: engine)
            let holder = GuestMemoryHolder()

            let hostImports = try buildHostImports(store: store, host: host, holder: holder)
            let instance: Instance
            do {
                instance = try module.instantiate(store: store, imports: hostImports)
            } catch {
                throw WasmEngineError.instantiationFailed(String(describing: error))
            }

            let mem: Memory
            if let exported = instance.exports[memory: "memory"] {
                mem = exported
            } else {
                mem = try Memory(store: store, type: MemoryType(min: 1, max: 2))
            }
            // Enforce max linear memory (WASM-005).
            let pageSize = 64 * 1024
            if mem.data.count > limits.maxLinearMemoryBytes {
                throw WasmEngineError.memoryLimitExceeded
            }
            // If memory has no declared max and current is under limit, still bind.
            _ = pageSize
            holder.setMemory(mem)

            return WasmKitInstance(
                engine: engine,
                store: store,
                instance: instance,
                memoryView: WasmKitMemoryView(memory: mem, limits: limits),
                limits: limits,
                memoryHolder: holder
            )
        }

        private init(
            engine: Engine,
            store: Store,
            instance: Instance,
            memoryView: WasmKitMemoryView,
            limits: WasmResourceLimits,
            memoryHolder: GuestMemoryHolder
        ) {
            self.engine = engine
            self.store = store
            self.instance = instance
            self.memoryView = memoryView
            self.limits = limits
            self.memoryHolder = memoryHolder
        }

        func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
            if isInterrupted {
                throw WasmEngineError.interrupted
            }
            guard let fn = instance.exports[function: name] else {
                throw WasmEngineError.missingExport(name)
            }
            let values = args.map { $0.toWasmKitValue() }
            let wall = limits.maxWallTime
            let holder = memoryHolder
            // Box for Sendable invoke across task boundary (WasmKit Function is not Sendable).
            final class InvokeBox: @unchecked Sendable {
                let fn: Function
                let values: [Value]
                init(fn: Function, values: [Value]) {
                    self.fn = fn
                    self.values = values
                }
                func run() throws -> [Value] { try fn.invoke(values) }
            }
            let box = InvokeBox(fn: fn, values: values)

            // Wall-time watchdog (WASM-004): race invoke vs deadline on a global queue.
            let results: [Value] = try await withThrowingTaskGroup(of: [Value].self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Value], Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                cont.resume(returning: try box.run())
                            } catch {
                                cont.resume(throwing: error)
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: wall)
                    holder.interrupt()
                    throw WasmEngineError.deadlineExceeded
                }
                do {
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                } catch {
                    group.cancelAll()
                    if holder.isInterrupted || self.isInterrupted {
                        if error is WasmEngineError { throw error }
                        throw WasmEngineError.interrupted
                    }
                    throw error
                }
            }

            state.withLock {
                $0.meters.budgetConsumed += 1
                $0.meters.memoryBytes = memoryView.size
            }
            return results.map { WasmValue.fromWasmKit($0) }
        }

        func interrupt() {
            memoryHolder.interrupt()
            state.withLock {
                $0.interrupted = true
                $0.meters.interrupted = true
            }
        }

        private static func buildHostImports(
            store: Store,
            host: WasmHostImports,
            holder: GuestMemoryHolder
        ) throws -> Imports {
            var imports = Imports()

            let send = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, args in
                let ptr = Int(Int32(bitPattern: args[0].i32))
                let len = Int32(bitPattern: args[1].i32)
                if len < 0 {
                    return [.i32(UInt32(bitPattern: CoreWasmABI.statusError))]
                }
                if len == 0 {
                    let rc = host.send(nil, 0)
                    return [.i32(UInt32(bitPattern: rc))]
                }
                do {
                    let data = try holder.read(offset: ptr, length: Int(len))
                    let rc = data.withUnsafeBytes { raw -> Int32 in
                        host.send(raw.baseAddress, len)
                    }
                    return [.i32(UInt32(bitPattern: rc))]
                } catch {
                    return [.i32(UInt32(bitPattern: CoreWasmABI.statusError))]
                }
            }

            let log = Function(store: store, parameters: [.i32, .i32, .i32], results: []) { _, args in
                let level = Int32(bitPattern: args[0].i32)
                let ptr = Int(Int32(bitPattern: args[1].i32))
                let len = Int32(bitPattern: args[2].i32)
                if len <= 0 {
                    host.log(level, nil, 0)
                    return []
                }
                if let data = try? holder.read(offset: ptr, length: Int(len)) {
                    data.withUnsafeBytes { raw in
                        host.log(level, raw.baseAddress, len)
                    }
                }
                return []
            }

            // Fixture modules import millis as () -> i32 (truncated).
            let millis = Function(store: store, parameters: [], results: [.i32]) { _, _ in
                let v = Int32(truncatingIfNeeded: host.monotonicMillis())
                return [.i32(UInt32(bitPattern: v))]
            }

            let cancel = Function(store: store, parameters: [.i64, .i64], results: [.i32]) { _, args in
                let a = Int64(bitPattern: args[0].i64)
                let b = Int64(bitPattern: args[1].i64)
                let rc = holder.shouldCancel(a: a, b: b, host: host)
                return [.i32(UInt32(bitPattern: rc))]
            }

            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostSend.rawValue, send)
            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostLog.rawValue, log)
            imports.define(
                module: CoreWasmImport.moduleName, name: CoreWasmImport.hostMonotonicMillis.rawValue, millis)
            imports.define(
                module: CoreWasmImport.moduleName, name: CoreWasmImport.hostShouldCancel.rawValue, cancel)
            return imports
        }
    }

    final class WasmKitMemoryView: WasmMemoryView, @unchecked Sendable {
        private let memory: Memory
        private let limits: WasmResourceLimits

        init(memory: Memory, limits: WasmResourceLimits) {
            self.memory = memory
            self.limits = limits
        }

        var size: Int { memory.data.count }

        func read(offset: Int, length: Int) throws -> Data {
            let total = memory.data.count
            guard offset >= 0, length >= 0, offset <= total, length <= total - offset else {
                throw WasmEngineError.trap("memory oob read")
            }
            if length == 0 { return Data() }
            return try memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                Data(buf)
            }
        }

        func write(offset: Int, data: Data) throws {
            let total = memory.data.count
            guard offset >= 0, data.count <= total - offset else {
                throw WasmEngineError.trap("memory oob write")
            }
            if data.isEmpty { return }
            memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: data.count) { dest in
                _ = data.copyBytes(to: dest)
            }
        }

        func grow(pages: Int) throws -> Int {
            let pageSize = 64 * 1024
            let currentBytes = memory.data.count
            let next = currentBytes + pages * pageSize
            if next > limits.maxLinearMemoryBytes {
                throw WasmEngineError.memoryLimitExceeded
            }
            // WasmKit Memory growth API is limited; refuse rather than soft-succeed.
            throw WasmEngineError.memoryLimitExceeded
        }
    }

    extension WasmValue {
        fileprivate func toWasmKitValue() -> Value {
            switch self {
            case .i32(let v): return .i32(UInt32(bitPattern: v))
            case .i64(let v): return .i64(UInt64(bitPattern: v))
            case .f32(let v): return .f32(v.bitPattern)
            case .f64(let v): return .f64(v.bitPattern)
            }
        }

        fileprivate static func fromWasmKit(_ v: Value) -> WasmValue {
            switch v {
            case .i32(let u): return .i32(Int32(bitPattern: u))
            case .i64(let u): return .i64(Int64(bitPattern: u))
            case .f32(let b): return .f32(Float(bitPattern: b))
            case .f64(let b): return .f64(Double(bitPattern: b))
            default: return .i32(0)
            }
        }
    }

    extension Value {
        fileprivate var i32: UInt32 {
            if case .i32(let v) = self { return v }
            return 0
        }
        fileprivate var i64: UInt64 {
            if case .i64(let v) = self { return v }
            return 0
        }
    }

#endif
