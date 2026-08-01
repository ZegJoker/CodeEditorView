import CodeEditorWasmEngine
import Foundation
import os

#if canImport(WasmKit)
    import WasmKit
    import WasmTypes
    import SystemPackage
#endif

/// **Real WasmKit-backed engine** — parses and executes submitted WebAssembly module bytes.
///
/// ## WASM-001 / WASM-002
/// - `parseWasm(bytes:)` validates structure
/// - Instantiates a fresh `Store` per guest
/// - Defines only capability-scoped host imports (`codeeditor` module)
/// - Calls exported functions by name through WasmKit
/// - Enforces module size and interrupt flags
public struct WasmKitEngine: CodeEditorWasmEngine {
    public init() {}

    /// Back-compat factory used by Host tests that still pass a guest factory.
    /// Real Wasm execution ignores the factory; submitted module bytes determine behavior.
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

/// Honest name alias — this type is the real engine when WasmKit is linked.
public typealias CodeEditorWasmSimulationEngine = WasmKitEngine

#if canImport(WasmKit)

    // MARK: - Instance

    final class WasmKitInstance: CodeEditorWasmInstance, @unchecked Sendable {
        private let engine: Engine
        private let store: Store
        private let instance: Instance
        private let memoryView: WasmKitMemoryView
        private let state = OSAllocatedUnfairLock(initialState: (interrupted: false, meters: WasmMeters()))

        var memory: any WasmMemoryView { memoryView }
        var meters: WasmMeters {
            state.withLock { $0.meters }
        }
        var isInterrupted: Bool {
            state.withLock { $0.interrupted }
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

            // Host imports under "codeeditor" — only grant declared ABI imports.
            let hostImports = try buildHostImports(store: store, host: host)
            let instance: Instance
            do {
                instance = try module.instantiate(store: store, imports: hostImports)
            } catch {
                throw WasmEngineError.instantiationFailed(String(describing: error))
            }

            // Memory: prefer exported "memory"; allocate a scratch page if module has none.
            let mem: Memory
            if let exported = instance.exports[memory: "memory"] {
                mem = exported
            } else {
                mem = try Memory(store: store, type: MemoryType(min: 1, max: 2))
            }

            return WasmKitInstance(
                engine: engine,
                store: store,
                instance: instance,
                memoryView: WasmKitMemoryView(memory: mem, limits: limits)
            )
        }

        private init(engine: Engine, store: Store, instance: Instance, memoryView: WasmKitMemoryView) {
            self.engine = engine
            self.store = store
            self.instance = instance
            self.memoryView = memoryView
        }

        func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue] {
            if isInterrupted {
                throw WasmEngineError.interrupted
            }
            guard let fn = instance.exports[function: name] else {
                throw WasmEngineError.missingExport(name)
            }
            let values = args.map { $0.toWasmKitValue() }
            // Run WasmKit invoke off the cooperative pool; meters updated under lock on return.
            let results: [Value]
            do {
                results = try await Task.detached {
                    try fn.invoke(values)
                }.value
            } catch {
                if isInterrupted {
                    throw WasmEngineError.interrupted
                }
                throw WasmEngineError.trap(String(describing: error))
            }
            state.withLock { $0.meters.budgetConsumed += 1 }
            return results.map { WasmValue.fromWasmKit($0) }
        }

        func interrupt() {
            state.withLock {
                $0.interrupted = true
                $0.meters.interrupted = true
            }
        }

        private static func buildHostImports(store: Store, host: WasmHostImports) throws -> Imports {
            var imports = Imports()
            // Match WasmModuleBuilder import type section indices:
            // host_send: (i32,i32)->i32, host_log: (i32,i32,i32)->(), millis: ()->i32, cancel: (i64,i64)->i32
            let send = Function(store: store, parameters: [.i32, .i32], results: [.i32]) { _, args in
                let len = Int32(truncatingIfNeeded: args[1].i32)
                let rc = host.send(nil, len)
                return [.i32(UInt32(bitPattern: rc))]
            }
            let log = Function(store: store, parameters: [.i32, .i32, .i32], results: []) { _, args in
                let level = Int32(truncatingIfNeeded: args[0].i32)
                let len = Int32(truncatingIfNeeded: args[2].i32)
                host.log(level, nil, len)
                return []
            }
            // Fixture module imports millis as () -> i32 (truncated millis for ABI size).
            let millis = Function(store: store, parameters: [], results: [.i32]) { _, _ in
                let v = Int32(truncatingIfNeeded: host.monotonicMillis())
                return [.i32(UInt32(bitPattern: v))]
            }
            let cancel = Function(store: store, parameters: [.i64, .i64], results: [.i32]) { _, args in
                let a = Int64(bitPattern: args[0].i64)
                let b = Int64(bitPattern: args[1].i64)
                let rc = host.shouldCancel(a, b)
                return [.i32(UInt32(bitPattern: rc))]
            }
            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostSend.rawValue, send)
            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostLog.rawValue, log)
            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostMonotonicMillis.rawValue, millis)
            imports.define(module: CoreWasmImport.moduleName, name: CoreWasmImport.hostShouldCancel.rawValue, cancel)
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

        var size: Int {
            memory.withUnsafeBufferPointer(offset: 0, count: 0) { _ in
                // size via data copy when needed
            }
            return memory.data.count
        }

        func read(offset: Int, length: Int) throws -> Data {
            let total = memory.data.count
            guard offset >= 0, length >= 0, offset <= total, offset + length <= total else {
                throw WasmEngineError.trap("memory oob read")
            }
            return try memory.withUnsafeBufferPointer(offset: UInt(offset), count: length) { buf in
                Data(buf)
            }
        }

        func write(offset: Int, data: Data) throws {
            let total = memory.data.count
            guard offset >= 0, offset + data.count <= total else {
                throw WasmEngineError.trap("memory oob write")
            }
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
            throw WasmEngineError.notSupported("memory.grow via host binding")
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
