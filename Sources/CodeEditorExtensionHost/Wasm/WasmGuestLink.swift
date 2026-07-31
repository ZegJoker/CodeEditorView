import Foundation
import CodeEditorWasmEngine
import CodeEditorWasmEngineWasmKit
import CodeEditorExtensionWasmGuest
import CodeEditorExtensionProtocol

/// Adapts ``WasmGuestRuntime`` to ``LinkedWasmGuest`` for the engine.
public final class WasmGuestLink: LinkedWasmGuest, @unchecked Sendable {
    public let runtime: WasmGuestRuntime
    private let memory: GuestMemory
    private var limits = WasmResourceLimits.default

    public init(runtime: WasmGuestRuntime = WasmGuestRuntime()) {
        self.runtime = runtime
        self.memory = GuestMemory(runtime: runtime)
    }

    public var memoryView: any WasmMemoryView { memory }

    public func bindHost(imports: WasmHostImports, limits: WasmResourceLimits) {
        self.limits = limits
        runtime.hostSend = { data in
            if data.isEmpty {
                return imports.send(nil, 0)
            }
            return data.withUnsafeBytes { raw in
                imports.send(raw.baseAddress, Int32(data.count))
            }
        }
        runtime.hostLog = { level, message in
            let bytes = Array(message.utf8)
            bytes.withUnsafeBytes { raw in
                imports.log(level, raw.baseAddress, Int32(bytes.count))
            }
        }
        runtime.hostMillis = { imports.monotonicMillis() }
        runtime.hostShouldCancel = { hi, lo in imports.shouldCancel(hi, lo) }
    }

    public func abiVersion() -> Int32 { runtime.abiVersion() }
    public func alloc(_ length: Int32) -> Int32 { runtime.alloc(length) }
    public func dealloc(_ ptr: Int32, _ length: Int32) { runtime.dealloc(ptr, length) }
    public func start(configPtr: Int32, configLen: Int32) -> Int32 {
        runtime.start(configPtr: configPtr, configLen: configLen)
    }
    public func receive(ptr: Int32, len: Int32) -> Int32 {
        runtime.receive(ptr: ptr, len: len)
    }
    public func poll(_ budget: Int32) -> Int32 { runtime.poll(budget) }
    public func stop(_ reason: Int32) { runtime.stop(reason) }
}

final class GuestMemory: WasmMemoryView, @unchecked Sendable {
    private let runtime: WasmGuestRuntime
    init(runtime: WasmGuestRuntime) { self.runtime = runtime }
    var size: Int { runtime.memory.count }
    func read(offset: Int, length: Int) throws -> Data {
        try runtime.read(ptr: offset, len: length)
    }
    func write(offset: Int, data: Data) throws {
        try runtime.writeToMemory(data, at: offset)
    }
    func grow(pages: Int) throws -> Int {
        let old = runtime.memory.count / 65536
        runtime.memory.append(Data(count: pages * 65536))
        return old
    }
}

/// Factory for host sessions.
public enum WasmEngineFactory {
    public static func linkedGuest() -> LinkedGuestWasmEngine {
        LinkedGuestWasmEngine {
            WasmGuestLink()
        }
    }

    public static func inProcess() -> InProcessCoreWasmEngine {
        InProcessCoreWasmEngine()
    }

    public static func wasmKit() -> WasmKitEngine {
        WasmKitEngine(guestFactory: { WasmGuestLink() })
    }
}
