import Foundation

/// Manages debug adapter sessions keyed by adapter id.
public actor DebugAdapterPool {
    public let log: DAPLog
    private var sessions: [String: DebugAdapterSession] = [:]
    private var testFactories: [String: @Sendable () async throws -> any DAPTransport] = [:]

    public init(log: DAPLog = DAPLog()) {
        self.log = log
    }

    public func registerTestFactory(
        id: String,
        factory: @escaping @Sendable () async throws -> any DAPTransport
    ) {
        testFactories[id] = factory
    }

    @discardableResult
    public func adapter(for definition: DebugAdapterDefinition) async throws -> DebugAdapterSession {
        let key = definition.poolKey
        if let existing = sessions[key] {
            let state = await existing.state
            if state == .running || state == .starting || state == .initialized || state == .configured || state == .stopped {
                return existing
            }
        }

        let factory: (@Sendable () async throws -> any DAPTransport)?
        switch definition.launch {
        case .test(let factoryID):
            guard let f = testFactories[factoryID] else {
                throw DAPError.unsupported("Unknown test factory \(factoryID)")
            }
            factory = f
        case .process, .connect, .custom:
            factory = nil
        }

        let session = DebugAdapterSession(
            definition: definition,
            log: log,
            transportFactory: factory
        )
        sessions[key] = session
        try await session.start()
        return session
    }

    public func session(id: DebugAdapterID) -> DebugAdapterSession? {
        sessions[id.rawValue]
    }

    public func shutdownAll() async {
        for session in sessions.values {
            await session.shutdown()
        }
        sessions.removeAll()
    }

    public func restart(id: DebugAdapterID, configuration: DAPJSONObject? = nil) async throws {
        guard let session = sessions[id.rawValue] else {
            throw DAPError.notRunning
        }
        try await session.restart(configuration: configuration)
    }

    public func remove(id: DebugAdapterID) async {
        if let session = sessions.removeValue(forKey: id.rawValue) {
            await session.shutdown()
        }
    }
}
