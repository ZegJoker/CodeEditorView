import Foundation

/// Ordered byte transport for a single terminal process (audit §21.5 / TER-N07).
///
/// Never silently drop bytes. Overflow must suspend the producer or fail the session.
public enum TerminalTransportEvent: Sendable, Hashable {
    case output(Data)
    /// Exact process exit reason (TER-N07) — never soft-map user cancel to exit 0.
    case terminated(TerminalProcessExitReason)
    case overflowTerminated(String)
    case error(String)

    /// Compatibility alias for exit-with-code.
    public static func exited(code: Int32) -> TerminalTransportEvent {
        .terminated(.exited(code: code))
    }
}

/// Exact termination taxonomy for PTY/process lifecycle (TER-N07).
public enum TerminalProcessExitReason: Sendable, Hashable {
    case exited(code: Int32)
    case signalled(signal: Int32)
    case cancelled
    case spawnFailed(String)
}

public struct TerminalProcessInfo: Sendable, Hashable {
    public var processId: Int32
    public var masterFD: Int32

    public init(processId: Int32, masterFD: Int32 = -1) {
        self.processId = processId
        self.masterFD = masterFD
    }
}

public enum TerminalTerminationReason: Sendable, Hashable {
    case user
    case processExited
    case error(String)
    case replaced
}

public struct TerminalLaunchRequest: Sendable, Hashable {
    public var configuration: TerminalConfiguration
    public var metadata: TerminalMetadata

    public init(
        configuration: TerminalConfiguration = TerminalConfiguration(),
        metadata: TerminalMetadata = .default
    ) {
        self.configuration = configuration
        self.metadata = metadata
    }
}

/// Session metadata for tasks/debug/shell integration (audit §21.7–21.8).
public struct TerminalMetadata: Sendable, Hashable {
    public var kind: TerminalSessionKind
    public var title: String
    public var taskID: String?
    public var debugSessionID: String?

    public init(
        kind: TerminalSessionKind = .terminal,
        title: String = "Terminal",
        taskID: String? = nil,
        debugSessionID: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.taskID = taskID
        self.debugSessionID = debugSessionID
    }

    public static let `default` = TerminalMetadata()
}

public enum TerminalSessionKind: String, Sendable, Hashable, Codable {
    case terminal
    case debuggee
    case task
}

public protocol TerminalByteTransport: Sendable {
    var events: AsyncThrowingStream<TerminalTransportEvent, Error> { get }
    func start(_ request: TerminalLaunchRequest) async throws -> TerminalProcessInfo
    func write(_ bytes: Data) async throws
    func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) async throws
    func terminate(_ reason: TerminalTerminationReason) async
}

/// Clamp terminal dimensions into the portable winsize range (TER-N07).
public enum TerminalDimension {
    public static let minCells = 1
    public static let maxCells = Int(UInt16.max)

    public static func clampCells(_ value: Int) -> UInt16 {
        let v = max(minCells, min(maxCells, value))
        return UInt16(v)
    }

    public static func clampPixels(_ value: Int) -> UInt32 {
        if value <= 0 { return 0 }
        if value >= Int(UInt32.max) { return UInt32.max }
        return UInt32(value)
    }
}

/// In-memory transport for tests: echoes writes, never drops.
public actor MockByteTransport: TerminalByteTransport {
    private var running = false
    private var cont: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation?
    public let events: AsyncThrowingStream<TerminalTransportEvent, Error>
    public private(set) var writeLog: [Data] = []
    /// When non-nil, next write throws overflow fatal (tests).
    public var failNextWriteWithOverflow: String?

    public init() {
        var c: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { c = $0 }
        self.cont = c
    }

    public func start(_ request: TerminalLaunchRequest) async throws -> TerminalProcessInfo {
        _ = request
        running = true
        return TerminalProcessInfo(processId: 1, masterFD: -1)
    }

    public func write(_ bytes: Data) async throws {
        guard running else { throw TerminalError.notRunning }
        if let msg = failNextWriteWithOverflow {
            failNextWriteWithOverflow = nil
            cont?.yield(.overflowTerminated(msg))
            cont?.finish()
            running = false
            throw TerminalError.startFailed(msg)
        }
        writeLog.append(bytes)
        cont?.yield(.output(bytes))
    }

    public func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) async throws {
        _ = (cols, rows, widthPx, heightPx)
        guard running else { throw TerminalError.sessionNotFound }
    }

    public func terminate(_ reason: TerminalTerminationReason) async {
        if running {
            switch reason {
            case .user, .replaced:
                cont?.yield(.terminated(.cancelled))
            case .processExited:
                cont?.yield(.terminated(.exited(code: 0)))
            case .error(let msg):
                cont?.yield(.terminated(.spawnFailed(msg)))
            }
            cont?.finish()
        }
        running = false
    }

    public func configureOverflow(_ message: String?) {
        failNextWriteWithOverflow = message
    }
}
