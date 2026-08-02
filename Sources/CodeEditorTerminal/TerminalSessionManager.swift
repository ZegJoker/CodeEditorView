import Foundation

/// Manages terminal sessions, optional screen models, and panel descriptors.
public actor TerminalSessionManager {
    private var backend: (any TerminalBackend)?
    private var sessions: [TerminalSessionID: TerminalSession] = [:]
    private var screens: [TerminalSessionID: TerminalScreen] = [:]
    private var pumpTask: Task<Void, Never>?

    public init() {}

    /// Attach a backend. **Terminates existing sessions** first (audit §20.17).
    public func attach(backend: any TerminalBackend) async {
        let existing = Array(sessions.keys)
        for id in existing {
            await close(id)
        }
        self.backend = backend
        pumpTask?.cancel()
        let stream = backend.output
        pumpTask = Task {
            for await event in stream {
                await self.handle(event)
            }
        }
    }

    public func create(
        title: String = "Terminal",
        configuration: TerminalConfiguration = TerminalConfiguration()
    ) async throws -> TerminalSession {
        guard let backend else { throw TerminalError.notRunning }
        let handle = try await backend.start(configuration: configuration)
        var session = TerminalSession(
            id: handle.id,
            title: title,
            configuration: configuration,
            isRunning: true
        )
        sessions[handle.id] = session
        screens[handle.id] = TerminalScreen(cols: configuration.cols, rows: configuration.rows)
        return session
    }

    public func write(_ text: String, to id: TerminalSessionID) async throws {
        try await write(Data(text.utf8), to: id)
    }

    public func write(_ data: Data, to id: TerminalSessionID) async throws {
        guard let backend else { throw TerminalError.notRunning }
        try await backend.write(data, to: id)
    }

    public func resize(cols: Int, rows: Int, session id: TerminalSessionID) async throws {
        guard let backend else { throw TerminalError.notRunning }
        try await backend.resize(cols: cols, rows: rows, session: id)
        screens[id]?.resize(cols: cols, rows: rows)
        if var s = sessions[id] {
            s.configuration.cols = cols
            s.configuration.rows = rows
            sessions[id] = s
        }
    }

    public func close(_ id: TerminalSessionID) async {
        await backend?.terminate(session: id)
        sessions[id]?.isRunning = false
        sessions.removeValue(forKey: id)
        screens.removeValue(forKey: id)
    }

    public func allSessions() -> [TerminalSession] {
        Array(sessions.values)
    }

    public func screen(for id: TerminalSessionID) -> TerminalScreen? {
        screens[id]
    }

    public func panelDescriptor(for id: TerminalSessionID) -> TerminalPanelDescriptor? {
        guard let s = sessions[id] else { return nil }
        return TerminalPanelDescriptor(id: id.rawValue.uuidString, title: s.title, sessionID: id)
    }

    /// Restore session configuration only (no process continuity promise).
    public func restorationSnapshots() -> [TerminalConfiguration] {
        sessions.values.map(\.configuration)
    }

    private func handle(_ event: TerminalOutputEvent) {
        switch event {
        case .data(let session, let bytes):
            screens[session]?.feed(bytes)
        case .exited(let session, _):
            if var s = sessions[session] {
                s.isRunning = false
                sessions[session] = s
            }
        }
    }
}
