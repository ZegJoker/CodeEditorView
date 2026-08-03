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
    /// Grow linear memory by `pages` (64 KiB each). Returns previous page count.
    /// Must enforce engine/host limits (WASM-N05); never soft-succeed.
    func grow(pages: Int) throws -> Int
}

/// Host functions provided to the guest module (core-Wasm ABI imports).
public struct WasmHostImports: Sendable {
    public var send: @Sendable (UnsafeRawPointer?, Int32) -> Int32
    public var log: @Sendable (Int32, UnsafeRawPointer?, Int32) -> Void
    /// Monotonic milliseconds as Int64 (no Int32 truncation). WASM-N07.
    public var monotonicMillis: @Sendable () -> Int64
    /// Cancellation probe keyed by request id high/low (WASM-N12). Never a sticky global flag.
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

/// Typed poll statuses (WASM-N13). Unknown values are ABI errors.
public enum CoreWasmPollStatus: Int32, Sendable, Hashable, CaseIterable {
    case idle = 0
    case guestError = 1
    case progress = 2
    case cancelled = 3
    case backpressure = 4
    case completed = 5
    case fatal = 6

    public static func parse(_ raw: Int32) throws -> CoreWasmPollStatus {
        guard let s = CoreWasmPollStatus(rawValue: raw) else {
            throw WasmEngineError.pollStatusUnknown(raw)
        }
        if s == .fatal {
            throw WasmEngineError.pollStatusFatal(raw)
        }
        return s
    }
}

public enum CoreWasmABI {
    public static let version: Int32 = 1

    public static let statusOK: Int32 = CoreWasmPollStatus.idle.rawValue
    public static let statusError: Int32 = CoreWasmPollStatus.guestError.rawValue
    public static let statusBusy: Int32 = CoreWasmPollStatus.progress.rawValue
    public static let statusCancelled: Int32 = CoreWasmPollStatus.cancelled.rawValue
    public static let statusBackpressure: Int32 = CoreWasmPollStatus.backpressure.rawValue
    public static let statusCompleted: Int32 = CoreWasmPollStatus.completed.rawValue
    public static let statusFatal: Int32 = CoreWasmPollStatus.fatal.rawValue

    /// Required function exports for core ABI activation.
    public static let requiredExports: [CoreWasmExport] = [
        .abiVersion, .alloc, .dealloc, .start, .receive, .poll, .stop,
    ]

    public static let requiredMemoryExport = "memory"
}

/// Serial runtime gate: one instance, one exclusive executor (WASM-N04).
///
/// Both Wasm **calls** and **memory** access for a given instance must share one
/// runtime so store/memory never race with `Function.invoke`. Implemented as a
/// dedicated serial queue (not a free-threaded lock + global queue hop).
public final class WasmSerialRuntime: @unchecked Sendable {
    /// Per-instance key so re-entrancy is detected only for *this* queue (WASM-N04).
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queue: DispatchQueue
    private let token: UInt8 = 1

    public init(label: String = "codeeditor.wasm.serial") {
        self.queue = DispatchQueue(label: label)
        self.queue.setSpecific(key: queueKey, value: token)
    }

    /// Run exclusively on the serial executor (sync). Used by memory read/write/grow.
    /// Re-entrant: if already on this queue, runs inline (avoids deadlock).
    public func runSync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == token {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    /// Run exclusively on the serial executor (async entry). Used by `call`.
    public func runAsync<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// Process-wide active instance counter (WASM-N10 `maxInstances`).
public final class WasmInstanceRegistry: @unchecked Sendable {
    public static let shared = WasmInstanceRegistry()

    private let lock = NSLock()
    private var active = 0

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func acquire(maxInstances: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if active >= maxInstances {
            throw WasmEngineError.resourceLimit("maxInstances \(active) >= \(maxInstances)")
        }
        active += 1
    }

    public func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }

    /// Test-only reset (never called from production paths).
    public func resetForTests() {
        lock.lock()
        active = 0
        lock.unlock()
    }
}

/// Capability-call meter shared by host import adapters (WASM-N10).
public final class WasmCapabilityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var windowStart = ContinuousClock.now
    private var windowCount = 0
    private let maxTotal: Int
    private let maxPerSecond: Int

    public init(maxTotal: Int, maxPerSecond: Int) {
        self.maxTotal = maxTotal
        self.maxPerSecond = maxPerSecond
    }

    public var totalCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// Record one capability call. Returns false if quota exceeded (fail closed).
    @discardableResult
    public func record() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if now - windowStart >= .seconds(1) {
            windowStart = now
            windowCount = 0
        }
        if total >= maxTotal { return false }
        if windowCount >= maxPerSecond { return false }
        total += 1
        windowCount += 1
        return true
    }
}
