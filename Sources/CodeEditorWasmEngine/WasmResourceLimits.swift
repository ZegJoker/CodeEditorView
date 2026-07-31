import Foundation

/// Hard limits for Wasm extension instances (enforced by host + engine).
public struct WasmResourceLimits: Sendable, Hashable, Codable {
    public var maxLinearMemoryBytes: Int
    public var maxWallTime: Duration
    public var maxPollBudgetPerTick: Int
    public var maxHostSendQueueBytes: Int
    public var maxHostSendQueueMessages: Int
    public var maxLogBytes: Int
    public var maxModuleBytes: Int
    public var maxConcurrentRequests: Int
    public var maxPollTicks: Int

    public init(
        maxLinearMemoryBytes: Int = 16 * 1024 * 1024,
        maxWallTime: Duration = .seconds(5),
        maxPollBudgetPerTick: Int = 10_000,
        maxHostSendQueueBytes: Int = 1 * 1024 * 1024,
        maxHostSendQueueMessages: Int = 256,
        maxLogBytes: Int = 256 * 1024,
        maxModuleBytes: Int = 8 * 1024 * 1024,
        maxConcurrentRequests: Int = 16,
        maxPollTicks: Int = 100_000
    ) {
        self.maxLinearMemoryBytes = maxLinearMemoryBytes
        self.maxWallTime = maxWallTime
        self.maxPollBudgetPerTick = maxPollBudgetPerTick
        self.maxHostSendQueueBytes = maxHostSendQueueBytes
        self.maxHostSendQueueMessages = maxHostSendQueueMessages
        self.maxLogBytes = maxLogBytes
        self.maxModuleBytes = maxModuleBytes
        self.maxConcurrentRequests = maxConcurrentRequests
        self.maxPollTicks = maxPollTicks
    }

    public static let `default` = WasmResourceLimits()

    public static let tight = WasmResourceLimits(
        maxLinearMemoryBytes: 64 * 1024,
        maxWallTime: .milliseconds(200),
        maxPollBudgetPerTick: 64,
        maxHostSendQueueBytes: 4096,
        maxHostSendQueueMessages: 8,
        maxLogBytes: 1024,
        maxModuleBytes: 256 * 1024,
        maxConcurrentRequests: 2,
        maxPollTicks: 500
    )
}

public struct WasmMeters: Sendable, Hashable {
    public var wallTimeStarted: Date
    public var pollTicks: Int
    public var budgetConsumed: Int
    public var memoryBytes: Int
    public var hostSendMessages: Int
    public var hostSendBytes: Int
    public var logBytes: Int
    public var interrupted: Bool

    public init(
        wallTimeStarted: Date = Date(),
        pollTicks: Int = 0,
        budgetConsumed: Int = 0,
        memoryBytes: Int = 0,
        hostSendMessages: Int = 0,
        hostSendBytes: Int = 0,
        logBytes: Int = 0,
        interrupted: Bool = false
    ) {
        self.wallTimeStarted = wallTimeStarted
        self.pollTicks = pollTicks
        self.budgetConsumed = budgetConsumed
        self.memoryBytes = memoryBytes
        self.hostSendMessages = hostSendMessages
        self.hostSendBytes = hostSendBytes
        self.logBytes = logBytes
        self.interrupted = interrupted
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
}
