import Foundation

/// Pinned Debug Adapter Protocol version for this host.
public enum DAPProtocolVersion {
    public static let major = 1
    public static let minor = 68
    public static var description: String { "\(major).\(minor)" }
}

public enum DAPError: Error, Sendable, Equatable {
    case transportClosed
    case timeout(method: String)
    case adapterError(code: Int, message: String)
    case decode(String)
    case encode(String)
    case notInitialized
    case crashed
    case unsupported(String)
    case alreadyStarted
    case notRunning
    case capabilityUnavailable(String)
    case framing(String)
    case budgetExceeded(String)
    case invalidState(String)
}

public enum DAPLogLevel: String, Sendable, Hashable, Codable {
    case debug, info, warning, error
}

public struct DAPLogEvent: Sendable, Hashable {
    public var level: DAPLogLevel
    public var message: String
    public var adapterID: String?
    public var date: Date

    public init(level: DAPLogLevel, message: String, adapterID: String? = nil, date: Date = Date()) {
        self.level = level
        self.message = message
        self.adapterID = adapterID
        self.date = date
    }
}

public final class DAPLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [DAPLogEvent] = []
    private let maxEvents: Int

    public init(maxEvents: Int = 500) {
        self.maxEvents = max(50, maxEvents)
    }

    public var events: [DAPLogEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    public func append(level: DAPLogLevel, message: String, adapterID: String? = nil) {
        let event = DAPLogEvent(level: level, message: message, adapterID: adapterID)
        lock.lock()
        _events.append(event)
        if _events.count > maxEvents {
            _events.removeFirst(_events.count - maxEvents)
        }
        lock.unlock()
    }
}

public struct DAPServerBudgets: Sendable, Hashable {
    public var requestTimeout: Duration
    public var maxBodyBytes: Int
    public var restartMaxAttempts: Int
    public var restartInitialBackoff: Duration
    public var restartMaxBackoff: Duration

    public init(
        requestTimeout: Duration = .seconds(15),
        maxBodyBytes: Int = 16 * 1024 * 1024,
        restartMaxAttempts: Int = 3,
        restartInitialBackoff: Duration = .milliseconds(200),
        restartMaxBackoff: Duration = .seconds(5)
    ) {
        self.requestTimeout = requestTimeout
        self.maxBodyBytes = maxBodyBytes
        self.restartMaxAttempts = restartMaxAttempts
        self.restartInitialBackoff = restartInitialBackoff
        self.restartMaxBackoff = restartMaxBackoff
    }

    public static let `default` = DAPServerBudgets()
}

/// JSON object wrapper (Sendable, not Codable of contents).
public struct DAPJSONObject: @unchecked Sendable {
    public let dictionary: [String: Any]

    public init(_ dictionary: [String: Any] = [:]) {
        self.dictionary = dictionary
    }

    public subscript(key: String) -> Any? { dictionary[key] }
}
