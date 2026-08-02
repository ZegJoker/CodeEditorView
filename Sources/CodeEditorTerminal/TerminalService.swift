import Foundation

/// Production terminal service: sessions backed by Ghostty engine + byte transport (TER-005).
///
/// Does **not** feed custom `VTParser`/`TerminalScreen`. UI consumes immutable UTF-8 snapshots
/// from the Ghostty controller path.
public actor TerminalService {
    public struct SessionState: Sendable {
        public var id: TerminalSessionID
        public var metadata: TerminalMetadata
        public var configuration: TerminalConfiguration
        public var isRunning: Bool
        public var processId: Int32?
        public var snapshotUTF8: String
    }

    private struct Live {
        var transport: any TerminalByteTransport
        var metadata: TerminalMetadata
        var configuration: TerminalConfiguration
        var isRunning: Bool
        var processId: Int32?
        var pump: Task<Void, Never>?
        var snapshot: String
        /// Optional Ghostty surface feed callback (ordered PTY output).
        var onOutput: (@Sendable (Data) async -> Void)?
    }

    private var sessions: [TerminalSessionID: Live] = [:]
    private var activeID: TerminalSessionID?
    public var securityPolicy: TerminalSecurityPolicy
    /// Production default is `true` (REL-N08 fail-closed). Tests must pass `false` explicitly when using mocks.
    public var requireGhosttyLinked: Bool
    public var isGhosttyLinked: @Sendable () -> Bool

    public init(
        securityPolicy: TerminalSecurityPolicy = .restricted,
        requireGhosttyLinked: Bool = true,
        isGhosttyLinked: @escaping @Sendable () -> Bool = { false }
    ) {
        self.securityPolicy = securityPolicy
        self.requireGhosttyLinked = requireGhosttyLinked
        self.isGhosttyLinked = isGhosttyLinked
    }

    public func allSessions() -> [SessionState] {
        sessions.map { id, live in
            SessionState(
                id: id,
                metadata: live.metadata,
                configuration: live.configuration,
                isRunning: live.isRunning,
                processId: live.processId,
                snapshotUTF8: live.snapshot
            )
        }
    }

    public func activeSessionID() -> TerminalSessionID? { activeID }

    public func setActive(_ id: TerminalSessionID?) {
        if let id, sessions[id] != nil {
            activeID = id
        } else if id == nil {
            activeID = nil
        }
    }

    public func snapshot(for id: TerminalSessionID) -> String? {
        sessions[id]?.snapshot
    }

    /// Create a session with the given transport factory (inject mock or LocalPTY).
    @discardableResult
    public func create(
        metadata: TerminalMetadata = .default,
        configuration: TerminalConfiguration = TerminalConfiguration(),
        transport: any TerminalByteTransport,
        onOutput: (@Sendable (Data) async -> Void)? = nil
    ) async throws -> TerminalSessionID {
        if requireGhosttyLinked && !isGhosttyLinked() {
            throw TerminalError.startFailed("Ghostty not linked; refuse production terminal session")
        }
        let id = TerminalSessionID()
        let info = try await transport.start(
            TerminalLaunchRequest(configuration: configuration, metadata: metadata)
        )
        var live = Live(
            transport: transport,
            metadata: metadata,
            configuration: configuration,
            isRunning: true,
            processId: info.processId,
            pump: nil,
            snapshot: "",
            onOutput: onOutput
        )
        let stream = transport.events
        live.pump = Task { [weak self] in
            do {
                for try await event in stream {
                    await self?.handle(event, session: id)
                }
            } catch {
                await self?.handle(.error(String(describing: error)), session: id)
            }
        }
        sessions[id] = live
        if activeID == nil { activeID = id }
        return id
    }

    public func write(_ data: Data, to id: TerminalSessionID) async throws {
        guard let live = sessions[id] else { throw TerminalError.sessionNotFound }
        try await live.transport.write(data)
    }

    public func write(_ text: String, to id: TerminalSessionID) async throws {
        try await write(Data(text.utf8), to: id)
    }

    public func resize(cols: Int, rows: Int, session id: TerminalSessionID) async throws {
        guard var live = sessions[id] else { throw TerminalError.sessionNotFound }
        try await live.transport.resize(cols: cols, rows: rows, widthPx: 0, heightPx: 0)
        live.configuration.cols = cols
        live.configuration.rows = rows
        sessions[id] = live
    }

    public func close(_ id: TerminalSessionID, reason: TerminalTerminationReason = .user) async {
        guard let live = sessions[id] else { return }
        live.pump?.cancel()
        await live.transport.terminate(reason)
        sessions[id] = nil
        if activeID == id {
            activeID = sessions.keys.first
        }
    }

    /// Close every session (e.g. backend replacement §20.17).
    public func closeAll(reason: TerminalTerminationReason = .replaced) async {
        let ids = Array(sessions.keys)
        for id in ids {
            await close(id, reason: reason)
        }
    }

    /// Restoration: configuration only (no process continuity).
    public func restorationSnapshots() -> [TerminalConfiguration] {
        sessions.values.map(\.configuration)
    }

    public func updateSnapshot(_ text: String, for id: TerminalSessionID) {
        sessions[id]?.snapshot = text
    }

    // MARK: - Private

    private func handle(_ event: TerminalTransportEvent, session id: TerminalSessionID) async {
        guard var live = sessions[id] else { return }
        switch event {
        case .output(let data):
            if let onOutput = live.onOutput {
                await onOutput(data)
            }
            // Append raw UTF-8 for accessibility fallback until Ghostty snapshot pull.
            if let s = String(data: data, encoding: .utf8) {
                live.snapshot += s
                // Bound snapshot memory for soak (100 MiB gate is separate; keep 4 MiB ring).
                if live.snapshot.utf8.count > 4 * 1024 * 1024 {
                    live.snapshot = String(live.snapshot.suffix(2 * 1024 * 1024))
                }
            }
            sessions[id] = live
        case .exited:
            live.isRunning = false
            sessions[id] = live
        case .overflowTerminated(let msg):
            live.isRunning = false
            live.snapshot += "\n[terminal overflow: \(msg)]\n"
            sessions[id] = live
        case .error(let msg):
            live.snapshot += "\n[terminal error: \(msg)]\n"
            sessions[id] = live
        }
    }
}
