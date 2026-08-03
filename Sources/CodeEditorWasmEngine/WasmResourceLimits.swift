import Foundation

/// Hard limits for Wasm extension instances (enforced by host + engine).
///
/// All fields are actively enforced (WASM-N10). Growth and table limits are
/// continuous via the engine resource limiter (WASM-N02).
public struct WasmResourceLimits: Sendable, Hashable, Codable {
    public var maxLinearMemoryBytes: Int
    /// Per-call wall-time budget (not session lifetime). WASM-N08.
    public var maxWallTime: Duration
    /// Optional CPU-equivalent budget (instruction fuel via metering). 0 = unlimited fuel beyond wall.
    public var maxFuel: UInt64
    public var maxPollBudgetPerTick: Int
    public var maxHostSendQueueBytes: Int
    public var maxHostSendQueueMessages: Int
    public var maxLogBytes: Int
    public var maxLogMessages: Int
    public var maxLogBytesPerSecond: Int
    public var maxModuleBytes: Int
    public var maxConcurrentRequests: Int
    public var maxPollTicks: Int
    public var maxPollTicksPerRequest: Int
    public var maxOutstandingGuestAllocations: Int
    public var maxRequestBytes: Int
    public var maxResponseBytes: Int
    public var maxTableElements: Int
    public var maxStackBytes: Int
    public var maxInstances: Int
    public var maxCapabilityCalls: Int
    public var maxCapabilityCallsPerSecond: Int
    /// When true, pure noncooperative guest work must run in a killable helper (WASM-N01).
    public var requireProcessIsolation: Bool
    /// Reject modules whose memory lacks a declared maximum unless engine limiter can impose one.
    public var requireMemoryMaximum: Bool

    public init(
        maxLinearMemoryBytes: Int = 16 * 1024 * 1024,
        maxWallTime: Duration = .seconds(5),
        maxFuel: UInt64 = 50_000_000,
        maxPollBudgetPerTick: Int = 10_000,
        maxHostSendQueueBytes: Int = 1 * 1024 * 1024,
        maxHostSendQueueMessages: Int = 256,
        maxLogBytes: Int = 256 * 1024,
        maxLogMessages: Int = 4_096,
        maxLogBytesPerSecond: Int = 64 * 1024,
        maxModuleBytes: Int = 8 * 1024 * 1024,
        maxConcurrentRequests: Int = 16,
        maxPollTicks: Int = 100_000,
        maxPollTicksPerRequest: Int = 10_000,
        maxOutstandingGuestAllocations: Int = 256,
        maxRequestBytes: Int = 1 * 1024 * 1024,
        maxResponseBytes: Int = 1 * 1024 * 1024,
        maxTableElements: Int = 10_000,
        maxStackBytes: Int = 512 * 1024,
        maxInstances: Int = 1,
        maxCapabilityCalls: Int = 10_000,
        maxCapabilityCallsPerSecond: Int = 1_000,
        requireProcessIsolation: Bool = false,
        requireMemoryMaximum: Bool = true
    ) {
        self.maxLinearMemoryBytes = maxLinearMemoryBytes
        self.maxWallTime = maxWallTime
        self.maxFuel = maxFuel
        self.maxPollBudgetPerTick = maxPollBudgetPerTick
        self.maxHostSendQueueBytes = maxHostSendQueueBytes
        self.maxHostSendQueueMessages = maxHostSendQueueMessages
        self.maxLogBytes = maxLogBytes
        self.maxLogMessages = maxLogMessages
        self.maxLogBytesPerSecond = maxLogBytesPerSecond
        self.maxModuleBytes = maxModuleBytes
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxPollTicks = maxPollTicks
        self.maxPollTicksPerRequest = maxPollTicksPerRequest
        self.maxOutstandingGuestAllocations = maxOutstandingGuestAllocations
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxTableElements = maxTableElements
        self.maxStackBytes = maxStackBytes
        self.maxInstances = maxInstances
        self.maxCapabilityCalls = maxCapabilityCalls
        self.maxCapabilityCallsPerSecond = maxCapabilityCallsPerSecond
        self.requireProcessIsolation = requireProcessIsolation
        self.requireMemoryMaximum = requireMemoryMaximum
    }

    public static let `default` = WasmResourceLimits()

    public static let tight = WasmResourceLimits(
        maxLinearMemoryBytes: 64 * 1024,
        maxWallTime: .milliseconds(200),
        maxFuel: 100_000,
        maxPollBudgetPerTick: 64,
        maxHostSendQueueBytes: 4096,
        maxHostSendQueueMessages: 8,
        maxLogBytes: 1024,
        maxLogMessages: 32,
        maxLogBytesPerSecond: 512,
        maxModuleBytes: 256 * 1024,
        maxConcurrentRequests: 2,
        maxPollTicks: 500,
        maxPollTicksPerRequest: 100,
        maxOutstandingGuestAllocations: 8,
        maxRequestBytes: 4096,
        maxResponseBytes: 4096,
        maxTableElements: 64,
        maxStackBytes: 64 * 1024,
        maxInstances: 1,
        maxCapabilityCalls: 32,
        maxCapabilityCallsPerSecond: 32,
        requireProcessIsolation: false,
        requireMemoryMaximum: true
    )
}

public struct WasmMeters: Sendable, Hashable {
    /// Monotonic start instant as nanoseconds from an arbitrary epoch (not wall Date). WASM-N07.
    public var wallTimeStartedNanos: Int64
    public var pollTicks: Int
    public var budgetConsumed: Int
    public var memoryBytes: Int
    public var hostSendMessages: Int
    public var hostSendBytes: Int
    public var logBytes: Int
    public var logMessages: Int
    public var logTruncations: Int
    public var fuelConsumed: UInt64
    public var outstandingAllocations: Int
    public var capabilityCalls: Int
    public var interrupted: Bool

    public init(
        wallTimeStartedNanos: Int64 = WasmMonotonicClock.nowNanos(),
        pollTicks: Int = 0,
        budgetConsumed: Int = 0,
        memoryBytes: Int = 0,
        hostSendMessages: Int = 0,
        hostSendBytes: Int = 0,
        logBytes: Int = 0,
        logMessages: Int = 0,
        logTruncations: Int = 0,
        fuelConsumed: UInt64 = 0,
        outstandingAllocations: Int = 0,
        capabilityCalls: Int = 0,
        interrupted: Bool = false
    ) {
        self.wallTimeStartedNanos = wallTimeStartedNanos
        self.pollTicks = pollTicks
        self.budgetConsumed = budgetConsumed
        self.memoryBytes = memoryBytes
        self.hostSendMessages = hostSendMessages
        self.hostSendBytes = hostSendBytes
        self.logBytes = logBytes
        self.logMessages = logMessages
        self.logTruncations = logTruncations
        self.fuelConsumed = fuelConsumed
        self.outstandingAllocations = outstandingAllocations
        self.capabilityCalls = capabilityCalls
        self.interrupted = interrupted
    }

    /// Compatibility accessor — prefers monotonic nanos converted to Date only for display.
    public var wallTimeStarted: Date {
        get {
            Date(timeIntervalSince1970: TimeInterval(wallTimeStartedNanos) / 1_000_000_000.0)
        }
        set {
            wallTimeStartedNanos = Int64(newValue.timeIntervalSince1970 * 1_000_000_000.0)
        }
    }
}

/// Process-wide monotonic clock for Wasm host ABI (WASM-N07).
public enum WasmMonotonicClock {
    private static let start = ContinuousClock.now

    /// Nanoseconds since first use (monotonic, non-truncating uptime for Int64 range).
    public static func nowNanos() -> Int64 {
        let elapsed = ContinuousClock.now - start
        let c = elapsed.components
        let nanos = c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
        return nanos
    }

    /// Milliseconds since first use as Int64 (full width, no Int32 truncate).
    public static func nowMillis() -> Int64 {
        nowNanos() / 1_000_000
    }
}

public enum WasmEngineError: Error, Sendable, Equatable {
    case moduleTooLarge(Int)
    case invalidModule(String)
    case missingExport(String)
    case missingImport(String)
    case trap(String)
    case interrupted
    case deadlineExceeded
    case memoryLimitExceeded
    case queueBackpressure
    case logLimitExceeded
    case notSupported(String)
    case linkError(String)
    case resourceLimit(String)
    case instantiationFailed(String)
    case unsupportedValueType(String)
    case abiValidation(String)
    case concurrentAccess
    case processIsolationRequired
    case allocationLimitExceeded
    case requestTooLarge(Int)
    case responseTooLarge(Int)
    case pollStatusUnknown(Int32)
    case pollStatusFatal(Int32)
}
