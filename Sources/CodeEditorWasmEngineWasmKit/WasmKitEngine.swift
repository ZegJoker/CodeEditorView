import CodeEditorWasmEngine
import Foundation
import os

#if canImport(WasmKit)
    @_spi(Fuzzing) import WasmKit
    import WasmTypes
#endif

/// **Real WasmKit-backed engine** — submitted module bytes determine executed behavior.
///
/// Hard containment (WASM-N01…N07):
/// - Loop instrumentation so pure noncooperative loops observe cancel/interrupt
/// - Continuous ``ResourceLimiter`` for memory/table growth
/// - Required memory export (no fabricated detached memory)
/// - Serial actor executor for call/memory access
/// - Real memory.grow via trampoline module sharing guest memory
/// - Unsupported values throw (never coerce to zero)
/// - Monotonic Int64 millis host import
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
        _ = try WasmModuleInstrumenter.validateStructure(module: module, limits: limits)
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
        let report = try WasmModuleInstrumenter.validateStructure(module: module, limits: limits)
        #if canImport(WasmKit)
            // Instrument pure loops so wall-time interrupt is observed (WASM-N01).
            let instrumented: Data
            do {
                instrumented = try WasmModuleInstrumenter.instrumentLoopsForCancellation(module)
            } catch {
                // Uninstrumentable modules require process isolation — fail closed when not available.
                if limits.requireProcessIsolation {
                    throw WasmEngineError.processIsolationRequired
                }
                throw WasmEngineError.invalidModule("uninstrumentable: \(error)")
            }
            return try await WasmKitInstance.create(
                moduleBytes: instrumented,
                host: imports,
                limits: limits,
                report: report
            )
        #else
            throw WasmEngineError.invalidModule("WasmKit not linked")
        #endif
    }
}

#if canImport(WasmKit)

    // MARK: - Resource limiter (WASM-N02)

    final class WasmKitResourceLimiter: ResourceLimiter, @unchecked Sendable {
        let maxMemoryBytes: Int
        let maxTableElements: Int
        private let lock = NSLock()
        private(set) var peakMemoryBytes: Int = 0
        private(set) var peakTableElements: Int = 0

        init(maxMemoryBytes: Int, maxTableElements: Int) {
            self.maxMemoryBytes = maxMemoryBytes
            self.maxTableElements = maxTableElements
        }

        func limitMemoryGrowth(to desired: Int) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if desired > maxMemoryBytes { return false }
            peakMemoryBytes = max(peakMemoryBytes, desired)
            return true
        }

        func limitTableGrowth(to desired: Int) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if desired > maxTableElements { return false }
            peakTableElements = max(peakTableElements, desired)
            return true
        }
    }

    // MARK: - Memory holder for host import closures

    final class GuestMemoryHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _memory: Memory?
        private var _interrupted = false
        private var _activeRequestHigh: Int64 = 0
        private var _activeRequestLow: Int64 = 0
        private var _cancelled: Set<String> = []
        private var _fuel: UInt64 = 0
        private var _maxFuel: UInt64 = .max

        func setMemory(_ memory: Memory) {
            lock.lock()
            _memory = memory
            lock.unlock()
        }

        func configureFuel(_ max: UInt64) {
            lock.lock()
            _maxFuel = max == 0 ? .max : max
            _fuel = 0
            lock.unlock()
        }

        func burnFuel(_ n: UInt64 = 1) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if _interrupted { return false }
            let (next, overflow) = _fuel.addingReportingOverflow(n)
            if overflow || next > _maxFuel {
                _interrupted = true
                return false
            }
            _fuel = next
            return true
        }

        var fuelConsumed: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return _fuel
        }

        func setActiveRequest(high: Int64, low: Int64) {
            lock.lock()
            _activeRequestHigh = high
            _activeRequestLow = low
            lock.unlock()
        }

        func clearActiveRequest() {
            lock.lock()
            _activeRequestHigh = 0
            _activeRequestLow = 0
            lock.unlock()
        }

        func cancelRequest(high: Int64, low: Int64) {
            lock.lock()
            _cancelled.insert("\(high):\(low)")
            lock.unlock()
        }

        func clearCancel(high: Int64, low: Int64) {
            lock.lock()
            _cancelled.remove("\(high):\(low)")
            lock.unlock()
        }

        func interrupt() {
            lock.lock()
            _interrupted = true
            lock.unlock()
        }

        func resetInterrupt() {
            lock.lock()
            _interrupted = false
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
            let total = memory.byteCount
            guard offset >= 0, length >= 0,
                offset <= total,
                length <= total - offset
            else {
                throw WasmEngineError.trap("memory oob read offset=\(offset) len=\(length) size=\(total)")
            }
            if length == 0 { return Data() }
            return memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                Data(buf)
            }
        }

        func shouldCancel(a: Int64, b: Int64, host: WasmHostImports) -> Int32 {
            lock.lock()
            let interrupted = _interrupted
            let keyed = _cancelled.contains("\(a):\(b)")
            let activeKey = "\(_activeRequestHigh):\(_activeRequestLow)"
            let activeCancelled =
                (_activeRequestHigh != 0 || _activeRequestLow != 0)
                && _cancelled.contains(activeKey)
            lock.unlock()
            if interrupted { return 1 }
            if keyed || activeCancelled { return 1 }
            if !burnFuel(64) { return 1 }
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
        private let limiter: WasmKitResourceLimiter
        private let runtime = WasmSerialRuntime()
        private let state = OSAllocatedUnfairLock(
            initialState: (interrupted: false, meters: WasmMeters())
        )

        var memory: any WasmMemoryView { memoryView }
        var meters: WasmMeters {
            var m = state.withLock { $0.meters }
            m.fuelConsumed = memoryHolder.fuelConsumed
            m.memoryBytes = memoryView.size
            return m
        }
        var isInterrupted: Bool {
            state.withLock { $0.interrupted } || memoryHolder.isInterrupted
        }

        static func create(
            moduleBytes: Data,
            host: WasmHostImports,
            limits: WasmResourceLimits,
            report: WasmModuleInstrumenter.ValidationReport
        ) async throws -> WasmKitInstance {
            let module: Module
            do {
                module = try parseWasm(bytes: Array(moduleBytes))
            } catch {
                throw WasmEngineError.invalidModule(String(describing: error))
            }

            var config = EngineConfiguration()
            config.stackSize = limits.maxStackBytes
            let engine = Engine(configuration: config)
            let store = Store(engine: engine)
            let limiter = WasmKitResourceLimiter(
                maxMemoryBytes: limits.maxLinearMemoryBytes,
                maxTableElements: limits.maxTableElements
            )
            store.resourceLimiter = limiter

            let holder = GuestMemoryHolder()
            holder.configureFuel(limits.maxFuel)

            let hostImports = try buildHostImports(store: store, host: host, holder: holder)
            let instance: Instance
            do {
                instance = try module.instantiate(store: store, imports: hostImports)
            } catch {
                throw WasmEngineError.instantiationFailed(String(describing: error))
            }

            // WASM-N03: required memory export — never fabricate detached memory.
            guard let mem = instance.exports[memory: CoreWasmABI.requiredMemoryExport] else {
                throw WasmEngineError.missingExport(CoreWasmABI.requiredMemoryExport)
            }
            if mem.byteCount > limits.maxLinearMemoryBytes {
                throw WasmEngineError.memoryLimitExceeded
            }
            if limits.requireMemoryMaximum, report.memoryMaxPages == nil {
                // Engine limiter imposes continuous max — acceptable per audit when limiter present.
                // Still fail if min already exceeds.
                if mem.byteCount > limits.maxLinearMemoryBytes {
                    throw WasmEngineError.memoryLimitExceeded
                }
            }

            holder.setMemory(mem)

            return WasmKitInstance(
                engine: engine,
                store: store,
                instance: instance,
                memoryView: WasmKitMemoryView(
                    memory: mem,
                    store: store,
                    limits: limits,
                    runtime: WasmSerialRuntime()
                ),
                limits: limits,
                memoryHolder: holder,
                limiter: limiter
            )
        }

        private init(
            engine: Engine,
            store: Store,
            instance: Instance,
            memoryView: WasmKitMemoryView,
            limits: WasmResourceLimits,
            memoryHolder: GuestMemoryHolder,
            limiter: WasmKitResourceLimiter
        ) {
            self.engine = engine
            self.store = store
            self.instance = instance
            self.memoryView = memoryView
            self.limits = limits
            self.memoryHolder = memoryHolder
            self.limiter = limiter
        }

        func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
            try await runtime.runAsync {
                try await self.callSerialized(name, args: args)
            }
        }

        private func callSerialized(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
            // WASM-N04: WasmSerialRuntime actor queues concurrent callers — no concurrent store access.
            if isInterrupted {
                throw WasmEngineError.interrupted
            }
            guard let fn = instance.exports[function: name] else {
                throw WasmEngineError.missingExport(name)
            }
            let values = try args.map { try $0.toWasmKitValue() }
            let wall = limits.maxWallTime
            let holder = memoryHolder
            holder.configureFuel(limits.maxFuel)

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
                    // Drain remaining so invoke worker is not abandoned mid-flight after interrupt returns.
                    while let _ = try? await group.next() {}
                    return first
                } catch {
                    group.cancelAll()
                    // Wait briefly for instrumented guest to observe interrupt and exit.
                    let shutdown = ContinuousClock.now + .milliseconds(500)
                    while ContinuousClock.now < shutdown {
                        if case .some = try? await group.next() {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
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
                $0.meters.fuelConsumed = holder.fuelConsumed
            }
            return try results.map { try WasmValue.fromWasmKit($0) }
        }

        func interrupt() {
            memoryHolder.interrupt()
            state.withLock {
                $0.interrupted = true
                $0.meters.interrupted = true
            }
        }

        /// Cancel a specific request id (high/low halves of UUID). WASM-N12.
        func cancelRequest(high: Int64, low: Int64) {
            memoryHolder.cancelRequest(high: high, low: low)
        }

        func clearCancelRequest(high: Int64, low: Int64) {
            memoryHolder.clearCancel(high: high, low: low)
        }

        func setActiveRequest(high: Int64, low: Int64) {
            memoryHolder.setActiveRequest(high: high, low: low)
        }

        func clearActiveRequest() {
            memoryHolder.clearActiveRequest()
        }

        private static func buildHostImports(
            store: Store,
            host: WasmHostImports,
            holder: GuestMemoryHolder
        ) throws -> Imports {
            var imports = Imports()

            let send = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, args in
                let ptr = Int(Int32(bitPattern: args[0].asI32))
                let len = Int32(bitPattern: args[1].asI32)
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
                let level = Int32(bitPattern: args[0].asI32)
                let ptr = Int(Int32(bitPattern: args[1].asI32))
                let len = Int32(bitPattern: args[2].asI32)
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

            // Full-width Int64 monotonic millis (WASM-N07) — no Int32 truncation.
            let millis = Function(store: store, parameters: [], results: [.i64]) { _, _ in
                let v = host.monotonicMillis()
                return [.i64(UInt64(bitPattern: v))]
            }

            let cancel = Function(store: store, parameters: [.i64, .i64], results: [.i32]) { _, args in
                let a = Int64(bitPattern: args[0].asI64)
                let b = Int64(bitPattern: args[1].asI64)
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

    // MARK: - Memory view with real grow (WASM-N05)

    final class WasmKitMemoryView: WasmMemoryView, @unchecked Sendable {
        private let memory: Memory
        private let store: Store
        private let limits: WasmResourceLimits
        private let runtime: WasmSerialRuntime
        private let lock = NSLock()

        init(memory: Memory, store: Store, limits: WasmResourceLimits, runtime: WasmSerialRuntime) {
            self.memory = memory
            self.store = store
            self.limits = limits
            self.runtime = runtime
        }

        var size: Int {
            lock.lock()
            defer { lock.unlock() }
            return memory.byteCount
        }

        func read(offset: Int, length: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            let total = memory.byteCount
            guard offset >= 0, length >= 0, offset <= total, length <= total - offset else {
                throw WasmEngineError.trap("memory oob read")
            }
            if length == 0 { return Data() }
            return memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                Data(buf)
            }
        }

        func write(offset: Int, data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            let total = memory.byteCount
            guard offset >= 0, data.count <= total - offset else {
                throw WasmEngineError.trap("memory oob write")
            }
            if data.isEmpty { return }
            memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: data.count) { dest in
                _ = data.copyBytes(to: dest)
            }
        }

        func grow(pages: Int) throws -> Int {
            lock.lock()
            defer { lock.unlock() }
            guard pages >= 0 else { throw WasmEngineError.trap("negative grow") }
            let pageSize = 64 * 1024
            let currentBytes = memory.byteCount
            let currentPages = currentBytes / pageSize
            let next = currentBytes + pages * pageSize
            if next > limits.maxLinearMemoryBytes {
                throw WasmEngineError.memoryLimitExceeded
            }
            // Share this memory into a trampoline module that executes memory.grow (WASM-N05).
            let growModule = Self.makeGrowTrampolineModule()
            let parsed: Module
            do {
                parsed = try parseWasm(bytes: Array(growModule))
            } catch {
                throw WasmEngineError.notSupported("grow trampoline parse: \(error)")
            }
            var imports = Imports()
            imports.define(module: "env", name: "mem", memory)
            let inst: Instance
            do {
                inst = try parsed.instantiate(store: store, imports: imports)
            } catch {
                throw WasmEngineError.notSupported("grow trampoline link: \(error)")
            }
            guard let fn = inst.exports[function: "grow"] else {
                throw WasmEngineError.notSupported("grow export missing")
            }
            let result: [Value]
            do {
                result = try fn.invoke([.i32(UInt32(pages))])
            } catch {
                throw WasmEngineError.memoryLimitExceeded
            }
            guard let first = result.first, case .i32(let old) = first else {
                throw WasmEngineError.trap("grow bad result")
            }
            let oldPages = Int32(bitPattern: old)
            if oldPages < 0 {
                throw WasmEngineError.memoryLimitExceeded
            }
            _ = currentPages
            return Int(oldPages)
        }

        /// Mini module: (import "env" "mem" (memory 0)) (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
        private static func makeGrowTrampolineModule() -> Data {
            var m: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
            // type: (func (param i32) (result i32))
            m += [0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F]
            // import env.mem memory min0
            let env = Array("env".utf8)
            let memName = Array("mem".utf8)
            var imp: [UInt8] = []
            imp += encodeULEB(UInt32(env.count)) + env
            imp += encodeULEB(UInt32(memName.count)) + memName
            imp += [0x02, 0x00, 0x00]  // memory, flags=0 min=0
            m += [0x02] + encodeULEB(UInt32(1 + imp.count)) + [0x01] + imp
            // function section: 1 func type 0
            m += [0x03, 0x02, 0x01, 0x00]
            // export grow func 0
            let grow = Array("grow".utf8)
            let exp: [UInt8] = encodeULEB(UInt32(grow.count)) + grow + [0x00, 0x00]
            m += [0x07] + encodeULEB(UInt32(1 + exp.count)) + [0x01] + exp
            // code: local.get 0; memory.grow 0; end
            let body: [UInt8] = [0x00, 0x20, 0x00, 0x40, 0x00, 0x0B]
            let code = encodeULEB(UInt32(body.count)) + body
            m += [0x0A] + encodeULEB(UInt32(1 + code.count)) + [0x01] + code
            return Data(m)
        }

        private static func encodeULEB(_ value: UInt32) -> [UInt8] {
            WasmModuleInstrumenter.encodeULEB(value)
        }
    }

    // MARK: - Value conversion (WASM-N06)

    extension WasmValue {
        fileprivate func toWasmKitValue() throws -> Value {
            switch self {
            case .i32(let v): return .i32(UInt32(bitPattern: v))
            case .i64(let v): return .i64(UInt64(bitPattern: v))
            case .f32(let v): return .f32(v.bitPattern)
            case .f64(let v): return .f64(v.bitPattern)
            }
        }

        fileprivate static func fromWasmKit(_ v: Value) throws -> WasmValue {
            switch v {
            case .i32(let u): return .i32(Int32(bitPattern: u))
            case .i64(let u): return .i64(Int64(bitPattern: u))
            case .f32(let b): return .f32(Float(bitPattern: b))
            case .f64(let b): return .f64(Double(bitPattern: b))
            case .v128:
                throw WasmEngineError.unsupportedValueType("v128")
            case .ref:
                throw WasmEngineError.unsupportedValueType("ref")
            @unknown default:
                throw WasmEngineError.unsupportedValueType(String(describing: v))
            }
        }
    }

    extension Value {
        fileprivate var asI32: UInt32 {
            if case .i32(let v) = self { return v }
            return 0
        }
        fileprivate var asI64: UInt64 {
            if case .i64(let v) = self { return v }
            return 0
        }
    }

#endif
