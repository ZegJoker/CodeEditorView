import CodeEditorWasmEngine
import Foundation
import os

#if canImport(WasmKit)
    @_spi(Fuzzing) import WasmKit
    import WasmTypes
#endif

/// **Real WasmKit-backed engine** — submitted module bytes determine executed behavior.
///
/// Hard containment (WASM-N01…N07, N10):
/// - Loop instrumentation so pure noncooperative loops observe cancel/interrupt
/// - Continuous ``ResourceLimiter`` for memory/table growth
/// - Required memory export (no fabricated detached memory)
/// - **Shared** ``WasmSerialRuntime`` for call **and** memory (WASM-N04)
/// - Real memory.grow via trampoline module sharing guest memory
/// - Unsupported values throw (never coerce to zero)
/// - Monotonic Int64 millis host import
/// - `maxInstances` / capability-call quotas enforced
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
            // Uninstrumentable modules fail closed (or require process isolation).
            let instrumented: Data
            do {
                instrumented = try WasmModuleInstrumenter.instrumentLoopsForCancellation(module)
            } catch {
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

    // MARK: - Memory / cancel / fuel holder

    final class GuestMemoryHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _memory: Memory?
        private var _interrupted = false
        private var _activeRequestHigh: Int64 = 0
        private var _activeRequestLow: Int64 = 0
        private var _cancelled: Set<String> = []
        private var _fuel: UInt64 = 0
        private var _maxFuel: UInt64 = .max
        let capabilityMeter: WasmCapabilityMeter

        init(capabilityMeter: WasmCapabilityMeter) {
            self.capabilityMeter = capabilityMeter
        }

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
        /// Single serial runtime shared by call + memory (WASM-N04).
        private let runtime: WasmSerialRuntime
        private let registryAcquired: Bool
        private let state = OSAllocatedUnfairLock(
            initialState: (interrupted: false, meters: WasmMeters())
        )

        var memory: any WasmMemoryView { memoryView }
        var meters: WasmMeters {
            var m = state.withLock { $0.meters }
            m.fuelConsumed = memoryHolder.fuelConsumed
            m.memoryBytes = memoryView.size
            m.capabilityCalls = memoryHolder.capabilityMeter.totalCalls
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
            // WASM-N10: maxInstances
            try WasmInstanceRegistry.shared.acquire(maxInstances: limits.maxInstances)

            do {
                let module: Module
                do {
                    module = try parseWasm(bytes: Array(moduleBytes))
                } catch {
                    WasmInstanceRegistry.shared.release()
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

                let capMeter = WasmCapabilityMeter(
                    maxTotal: limits.maxCapabilityCalls,
                    maxPerSecond: limits.maxCapabilityCallsPerSecond
                )
                let holder = GuestMemoryHolder(capabilityMeter: capMeter)
                holder.configureFuel(limits.maxFuel)

                let hostImports = try buildHostImports(store: store, host: host, holder: holder)
                let instance: Instance
                do {
                    instance = try module.instantiate(store: store, imports: hostImports)
                } catch {
                    WasmInstanceRegistry.shared.release()
                    throw WasmEngineError.instantiationFailed(String(describing: error))
                }

                // WASM-N03: required memory export — never fabricate detached memory.
                guard let mem = instance.exports[memory: CoreWasmABI.requiredMemoryExport] else {
                    WasmInstanceRegistry.shared.release()
                    throw WasmEngineError.missingExport(CoreWasmABI.requiredMemoryExport)
                }
                if mem.byteCount > limits.maxLinearMemoryBytes {
                    WasmInstanceRegistry.shared.release()
                    throw WasmEngineError.memoryLimitExceeded
                }
                if limits.requireMemoryMaximum, report.memoryMaxPages == nil {
                    if mem.byteCount > limits.maxLinearMemoryBytes {
                        WasmInstanceRegistry.shared.release()
                        throw WasmEngineError.memoryLimitExceeded
                    }
                }

                holder.setMemory(mem)

                // One serial runtime shared by calls and memory view (WASM-N04).
                let runtime = WasmSerialRuntime(label: "codeeditor.wasm.instance.\(UUID().uuidString)")

                return WasmKitInstance(
                    engine: engine,
                    store: store,
                    instance: instance,
                    memoryView: WasmKitMemoryView(
                        memory: mem,
                        store: store,
                        limits: limits,
                        runtime: runtime
                    ),
                    limits: limits,
                    memoryHolder: holder,
                    limiter: limiter,
                    runtime: runtime,
                    registryAcquired: true
                )
            } catch {
                // acquire already released on known failure paths; rethrow others after release
                if error is WasmEngineError {
                    throw error
                }
                WasmInstanceRegistry.shared.release()
                throw error
            }
        }

        private init(
            engine: Engine,
            store: Store,
            instance: Instance,
            memoryView: WasmKitMemoryView,
            limits: WasmResourceLimits,
            memoryHolder: GuestMemoryHolder,
            limiter: WasmKitResourceLimiter,
            runtime: WasmSerialRuntime,
            registryAcquired: Bool
        ) {
            self.engine = engine
            self.store = store
            self.instance = instance
            self.memoryView = memoryView
            self.limits = limits
            self.memoryHolder = memoryHolder
            self.limiter = limiter
            self.runtime = runtime
            self.registryAcquired = registryAcquired
        }

        deinit {
            if registryAcquired {
                WasmInstanceRegistry.shared.release()
            }
        }

        func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
            // Enter serial runtime first so concurrent callers and memory ops queue (WASM-N04).
            try await runtime.runAsync {
                try self.callSerialized(name, args: args)
            }
        }

        /// Invoke on the serial queue (no free-threaded DispatchQueue.global hop).
        private func callSerialized(_ name: String, args: [WasmValue]) throws -> [WasmValue] {
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

            // Wall-time interrupt from a side thread while invoke runs on the serial queue.
            // Instrumented pure loops observe the interrupt flag via host_should_cancel probes.
            let interruptBox = holder
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let deadlineNanos = durationToNanos(wall)
            timer.schedule(deadline: .now() + .nanoseconds(Int(min(deadlineNanos, Int64(Int.max)))))
            timer.setEventHandler { interruptBox.interrupt() }
            timer.resume()
            defer { timer.cancel() }

            let results: [Value]
            do {
                results = try fn.invoke(values)
            } catch {
                if holder.isInterrupted {
                    throw WasmEngineError.deadlineExceeded
                }
                throw WasmEngineError.trap(String(describing: error))
            }

            if holder.isInterrupted {
                // Completed after interrupt was raised (fuel/wall) — still fail closed.
                throw WasmEngineError.interrupted
            }

            // Do not call memoryView.size here — it re-enters the serial queue (deadlock).
            let memBytes = memoryView.sizeUnlocked
            state.withLock {
                $0.meters.budgetConsumed += 1
                $0.meters.memoryBytes = memBytes
                $0.meters.fuelConsumed = holder.fuelConsumed
                $0.meters.capabilityCalls = holder.capabilityMeter.totalCalls
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

        private func durationToNanos(_ d: Duration) -> Int64 {
            let c = d.components
            return c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
        }

        private static func buildHostImports(
            store: Store,
            host: WasmHostImports,
            holder: GuestMemoryHolder
        ) throws -> Imports {
            var imports = Imports()

            let send = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, args in
                // WASM-N10: capability call quota (host_send is a capability).
                if !holder.capabilityMeter.record() {
                    return [.i32(UInt32(bitPattern: CoreWasmABI.statusBackpressure))]
                }
                let ptr = Int(try args[0].requireI32())
                let len = Int32(bitPattern: try args[1].requireI32())
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
                if !holder.capabilityMeter.record() {
                    return []
                }
                let level = Int32(bitPattern: try args[0].requireI32())
                let ptr = Int(try args[1].requireI32())
                let len = Int32(bitPattern: try args[2].requireI32())
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
                let a = Int64(bitPattern: try args[0].requireI64())
                let b = Int64(bitPattern: try args[1].requireI64())
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

    // MARK: - Memory view with real grow (WASM-N05) + serial runtime (WASM-N04)

    final class WasmKitMemoryView: WasmMemoryView, @unchecked Sendable {
        private let memory: Memory
        private let store: Store
        private let limits: WasmResourceLimits
        /// Same runtime as the owning instance's `call` path.
        private let runtime: WasmSerialRuntime

        init(memory: Memory, store: Store, limits: WasmResourceLimits, runtime: WasmSerialRuntime) {
            self.memory = memory
            self.store = store
            self.limits = limits
            self.runtime = runtime
        }

        /// Byte size without taking the serial queue (call path already holds it).
        var sizeUnlocked: Int { memory.byteCount }

        var size: Int {
            runtime.runSync { memory.byteCount }
        }

        func read(offset: Int, length: Int) throws -> Data {
            try runtime.runSync {
                let total = memory.byteCount
                guard offset >= 0, length >= 0, offset <= total, length <= total - offset else {
                    throw WasmEngineError.trap("memory oob read")
                }
                if length == 0 { return Data() }
                return memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                    Data(buf)
                }
            }
        }

        func write(offset: Int, data: Data) throws {
            try runtime.runSync {
                let total = memory.byteCount
                guard offset >= 0, data.count <= total - offset else {
                    throw WasmEngineError.trap("memory oob write")
                }
                if data.isEmpty { return }
                memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: data.count) { dest in
                    _ = data.copyBytes(to: dest)
                }
            }
        }

        func grow(pages: Int) throws -> Int {
            try runtime.runSync {
                guard pages >= 0 else { throw WasmEngineError.trap("negative grow") }
                let pageSize = 64 * 1024
                let currentBytes = memory.byteCount
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
                guard let first = result.first else {
                    throw WasmEngineError.trap("grow empty result")
                }
                // Fail closed: never coerce non-i32 to zero (WASM-N06).
                let old = try first.requireI32()
                let oldPages = Int32(bitPattern: old)
                if oldPages < 0 {
                    throw WasmEngineError.memoryLimitExceeded
                }
                return Int(oldPages)
            }
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

        /// Public fail-closed decode for regression tests (WASM-N06).
        public static func fromWasmKitValue(_ v: Value) throws -> WasmValue {
            try fromWasmKit(v)
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
        /// Fail closed — never coerce kind mismatch to zero (WASM-N06).
        fileprivate func requireI32() throws -> UInt32 {
            if case .i32(let v) = self { return v }
            throw WasmEngineError.unsupportedValueType("expected i32 got \(self)")
        }

        fileprivate func requireI64() throws -> UInt64 {
            if case .i64(let v) = self { return v }
            throw WasmEngineError.unsupportedValueType("expected i64 got \(self)")
        }
    }

#endif
