import Foundation

public enum ExtensionInactiveReason: Hashable, Codable, Sendable {
    case registered
    case incompatibleAPI
    case missingCapabilities
    case deactivated
    case waitingForEvent
}

public enum ExtensionState: Hashable, Codable, Sendable {
    case registered
    case inactive(ExtensionInactiveReason)
    case activating
    case active
    case failed(String)
    case deactivating
}

public struct ExtensionStatus: Hashable, Codable, Sendable {
    public var id: ExtensionID
    public var displayName: String
    public var state: ExtensionState
    public var grantedPermissions: Set<ExtensionPermission>
    public var lastError: String?

    public init(
        id: ExtensionID,
        displayName: String,
        state: ExtensionState,
        grantedPermissions: Set<ExtensionPermission> = [],
        lastError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.grantedPermissions = grantedPermissions
        self.lastError = lastError
    }
}

public enum ExtensionLogLevel: String, Hashable, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct ExtensionLogEvent: Hashable, Codable, Sendable {
    public var extensionID: ExtensionID?
    public var level: ExtensionLogLevel
    public var message: String
    public var date: Date

    public init(
        extensionID: ExtensionID? = nil,
        level: ExtensionLogLevel,
        message: String,
        date: Date = Date()
    ) {
        self.extensionID = extensionID
        self.level = level
        self.message = message
        self.date = date
    }
}

/// Append-only log shared by runtime and contexts.
public final class ExtensionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ExtensionLogEvent] = []
    private var maxEvents: Int

    public init(maxEvents: Int = 500) {
        self.maxEvents = max(50, maxEvents)
    }

    public var events: [ExtensionLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func append(
        extensionID: ExtensionID? = nil,
        level: ExtensionLogLevel,
        message: String
    ) {
        let event = ExtensionLogEvent(
            extensionID: extensionID,
            level: level,
            message: message
        )
        lock.lock()
        _events.append(event)
        if _events.count > maxEvents {
            _events.removeFirst(_events.count - maxEvents)
        }
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        _events.removeAll()
        lock.unlock()
    }
}
