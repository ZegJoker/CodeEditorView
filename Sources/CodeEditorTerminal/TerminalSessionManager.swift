import Foundation

public actor TerminalSessionManager {
    private var sessions: [TerminalSessionID: TerminalSession] = [:]
    private var backend: (any TerminalBackend)?

    public init() {}

    public func attach(backend: any TerminalBackend) {
        self.backend = backend
    }

    @discardableResult
    public func create(
        title: String = "Terminal",
        configuration: TerminalConfiguration = TerminalConfiguration()
    ) async throws -> TerminalSession {
        guard let backend else { throw TerminalError.notRunning }
        let handle = try await backend.start(configuration: configuration)
        let session = TerminalSession(
            id: handle.id,
            title: title,
            configuration: configuration,
            isRunning: true
        )
        sessions[session.id] = session
        return session
    }

    public func allSessions() -> [TerminalSession] {
        Array(sessions.values).sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    public func write(_ text: String, to id: TerminalSessionID) async throws {
        guard let backend else { throw TerminalError.notRunning }
        try await backend.write(Data(text.utf8), to: id)
    }

    public func close(_ id: TerminalSessionID) async {
        await backend?.terminate(session: id)
        if var s = sessions[id] {
            s.isRunning = false
            sessions[id] = s
        }
        sessions.removeValue(forKey: id)
    }

    public func panelDescriptor(for id: TerminalSessionID) -> TerminalPanelDescriptor? {
        guard let s = sessions[id] else { return nil }
        return TerminalPanelDescriptor(
            id: "terminal.\(id.rawValue.uuidString)",
            title: s.title,
            sessionID: id
        )
    }
}
