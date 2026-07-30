import Foundation

public enum LSPError: Error, Sendable, Equatable {
    case transportClosed
    case timeout(method: String)
    case serverError(code: Int, message: String)
    case decode(String)
    case encode(String)
    case notInitialized
    case crashed
    case unsupported(String)
    case alreadyStarted
    case notRunning
}

public enum LSPLogLevel: String, Sendable, Hashable, Codable {
    case debug
    case info
    case warning
    case error
}

public struct LSPLogEvent: Sendable, Hashable {
    public var level: LSPLogLevel
    public var message: String
    public var serverID: String?
    public var date: Date

    public init(
        level: LSPLogLevel,
        message: String,
        serverID: String? = nil,
        date: Date = Date()
    ) {
        self.level = level
        self.message = message
        self.serverID = serverID
        self.date = date
    }
}

public final class LSPLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LSPLogEvent] = []
    private let maxEvents: Int

    public init(maxEvents: Int = 500) {
        self.maxEvents = max(50, maxEvents)
    }

    public var events: [LSPLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func append(level: LSPLogLevel, message: String, serverID: String? = nil) {
        let event = LSPLogEvent(level: level, message: message, serverID: serverID)
        lock.lock()
        _events.append(event)
        if _events.count > maxEvents {
            _events.removeFirst(_events.count - maxEvents)
        }
        lock.unlock()
    }
}
