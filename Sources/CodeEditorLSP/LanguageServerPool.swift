import Foundation

/// Manages language server sessions keyed by definition pool key (id + workspace roots).
public actor LanguageServerPool {
    public let log: LSPLog
    private var sessions: [String: LanguageServerSession] = [:]
    private var testFactories: [String: @Sendable () async throws -> any LSPTransport] = [:]

    public init(log: LSPLog = LSPLog()) {
        self.log = log
    }

    public func registerTestFactory(
        id: String,
        factory: @escaping @Sendable () async throws -> any LSPTransport
    ) {
        testFactories[id] = factory
    }

    @discardableResult
    public func server(for definition: LanguageServerDefinition) async throws -> LanguageServerSession {
        let key = definition.poolKey
        if let existing = sessions[key] {
            let state = await existing.state
            if state == .running || state == .starting {
                return existing
            }
        }

        let factory: (@Sendable () async throws -> any LSPTransport)?
        switch definition.launch {
        case .test(let factoryID):
            guard let f = testFactories[factoryID] else {
                throw LSPError.unsupported("Unknown test factory \(factoryID)")
            }
            factory = f
        case .process, .custom:
            factory = nil
        }

        let session = LanguageServerSession(
            definition: definition,
            log: log,
            transportFactory: factory
        )
        sessions[key] = session
        try await session.start()
        return session
    }

    public func session(poolKey: String) -> LanguageServerSession? {
        sessions[poolKey]
    }

    public func sessionMatching(id: LanguageServerID) async -> LanguageServerSession? {
        for session in sessions.values {
            if await session.id == id {
                return session
            }
        }
        return nil
    }

    public func shutdownAll() async {
        for session in sessions.values {
            await session.shutdown()
        }
        sessions.removeAll()
    }

    public func restart(id: LanguageServerID) async throws {
        guard let session = await sessionMatching(id: id) else {
            throw LSPError.notRunning
        }
        try await session.restart()
    }
}
