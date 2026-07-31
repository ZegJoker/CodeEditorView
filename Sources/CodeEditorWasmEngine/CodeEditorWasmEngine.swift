import Foundation

public enum WasmValue: Sendable, Hashable {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)

    public var i32: Int32? {
        if case .i32(let v) = self { return v }
        return nil
    }

    public var i64: Int64? {
        if case .i64(let v) = self { return v }
        return nil
    }
}

public protocol WasmMemoryView: Sendable {
    var size: Int { get }
    func read(offset: Int, length: Int) throws -> Data
    func write(offset: Int, data: Data) throws
    func grow(pages: Int) throws -> Int
}

/// Host functions provided to the guest module (core-Wasm ABI imports).
public struct WasmHostImports: Sendable {
    public var send: @Sendable (UnsafeRawPointer?, Int32) -> Int32
    public var log: @Sendable (Int32, UnsafeRawPointer?, Int32) -> Void
    public var monotonicMillis: @Sendable () -> Int64
    public var shouldCancel: @Sendable (Int64, Int64) -> Int32

    public init(
        send: @escaping @Sendable (UnsafeRawPointer?, Int32) -> Int32,
        log: @escaping @Sendable (Int32, UnsafeRawPointer?, Int32) -> Void,
        monotonicMillis: @escaping @Sendable () -> Int64,
        shouldCancel: @escaping @Sendable (Int64, Int64) -> Int32
    ) {
        self.send = send
        self.log = log
        self.monotonicMillis = monotonicMillis
        self.shouldCancel = shouldCancel
    }
}

/// Portable Wasm engine contract (WasmKit is the reference backend).
public protocol CodeEditorWasmEngine: Sendable {
    func validate(module: Data, limits: WasmResourceLimits) throws
    func instantiate(
        module: Data,
        imports: WasmHostImports,
        limits: WasmResourceLimits
    ) async throws -> any CodeEditorWasmInstance
}

public protocol CodeEditorWasmInstance: AnyObject, Sendable {
    func call(_ name: String, args: [WasmValue]) async throws -> [WasmValue]
    var memory: any WasmMemoryView { get }
    func interrupt()
    var meters: WasmMeters { get }
    var isInterrupted: Bool { get }
}

/// Core-Wasm ABI export names (§9.5).
public enum CoreWasmExport: String, Sendable, CaseIterable {
    case abiVersion = "codeeditor_abi_version"
    case alloc = "codeeditor_alloc"
    case dealloc = "codeeditor_dealloc"
    case start = "codeeditor_start"
    case receive = "codeeditor_receive"
    case poll = "codeeditor_poll"
    case stop = "codeeditor_stop"
}

public enum CoreWasmImport: String, Sendable, CaseIterable {
    case hostSend = "codeeditor_host_send"
    case hostLog = "codeeditor_host_log"
    case hostMonotonicMillis = "codeeditor_host_monotonic_millis"
    case hostShouldCancel = "codeeditor_host_should_cancel"

    public static let moduleName = "codeeditor"
}

public enum CoreWasmABI {
    public static let version: Int32 = 1

    public static let statusOK: Int32 = 0
    public static let statusError: Int32 = 1
    public static let statusBusy: Int32 = 2
    public static let statusCancelled: Int32 = 3
    public static let statusBackpressure: Int32 = 4
}
