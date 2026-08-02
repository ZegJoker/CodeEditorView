import CodeEditorCore
import Foundation

/// Production terminal service: sessions backed by Ghostty engine + byte transport (TER-N01…N07).
///
/// Does **not** feed custom `VTParser`/`TerminalScreen`. Display state is owned by
/// Ghostty (via `onOutput` feed); this service never decodes process chunks as
/// standalone UTF-8 strings (TER-N05) and never appends full scrollback snapshots
/// on every chunk (TER-N06).
public actor TerminalService {
    public struct SessionState: Sendable {
        public var id: TerminalSessionID
        public var metadata: TerminalMetadata
        public var configuration: TerminalConfiguration
        public var isRunning: Bool
        public var processId: Int32?
        /// Last Ghostty-derived viewport text (host-updated), never chunk-decoded.
        public var viewportPlainText: String
        public var bytesReceived: UInt64
        public var viewportGeneration: UInt64
        public var lastExitReason: TerminalProcessExitReason?

        /// Compatibility: prefer `viewportPlainText`.
        public var snapshotUTF8: String { viewportPlainText }
    }

    /// Paged scrollback / search surface (TER-N06) — host pulls ranges, no O(n²) full copies.
    public struct ScrollbackPage: Sendable, Hashable {
        public var absoluteOffset: UInt64
        public var data: Data
        public var leadingTruncated: Bool
        public var availableStart: UInt64
        public var availableEnd: UInt64
    }

    private struct Live {
        var transport: any TerminalByteTransport
        var metadata: TerminalMetadata
        var configuration: TerminalConfiguration
        var isRunning: Bool
        var processId: Int32?
        var pump: Task<Void, Never>?
        var viewportPlainText: String
        var bytesReceived: UInt64
        var viewportGeneration: UInt64
        var lastExitReason: TerminalProcessExitReason?
        var rawSpool: BoundedByteSpool
        /// Optional Ghostty surface feed callback (ordered PTY output, raw bytes).
        var onOutput: (@Sendable (Data) async -> Void)?
        var eventHub: AsyncBroadcastHub<TerminalTransportEvent>
    }

    private var sessions: [TerminalSessionID: Live] = [:]
    private var activeID: TerminalSessionID?
    public var securityPolicy: TerminalSecurityPolicy
    /// Production default is `true` (REL-N08 / TER-N01 fail-closed). Tests must pass `false` explicitly when using mocks.
    public var requireGhosttyLinked: Bool
    public var isGhosttyLinked: @Sendable () -> Bool
    /// Bound for raw byte spool used only for paged diagnostics (not display model).
    public let maxRawSpoolBytes: Int

    public init(
        securityPolicy: TerminalSecurityPolicy = .restricted,
        requireGhosttyLinked: Bool = true,
        isGhosttyLinked: @escaping @Sendable () -> Bool = { false },
        maxRawSpoolBytes: Int = 4 * 1024 * 1024
    ) {
        self.securityPolicy = securityPolicy
        self.requireGhosttyLinked = requireGhosttyLinked
        self.isGhosttyLinked = isGhosttyLinked
        self.maxRawSpoolBytes = max(64 * 1024, maxRawSpoolBytes)
    }

    public func allSessions() -> [SessionState] {
        sessions.map { id, live in
            SessionState(
                id: id,
                metadata: live.metadata,
                configuration: live.configuration,
                isRunning: live.isRunning,
                processId: live.processId,
                viewportPlainText: live.viewportPlainText,
                bytesReceived: live.bytesReceived,
                viewportGeneration: live.viewportGeneration,
                lastExitReason: live.lastExitReason
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
        sessions[id]?.viewportPlainText
    }

    public func viewportGeneration(for id: TerminalSessionID) -> UInt64? {
        sessions[id]?.viewportGeneration
    }

    public func bytesReceived(for id: TerminalSessionID) -> UInt64? {
        sessions[id]?.bytesReceived
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
            throw TerminalError.startFailed(
                "Ghostty not linked; refuse production terminal session (set CODEEDITOR_GHOSTTY_LINKED=1)"
            )
        }
        let id = TerminalSessionID()
        let info = try await transport.start(
            TerminalLaunchRequest(configuration: configuration, metadata: metadata)
        )
        let hub = AsyncBroadcastHub<TerminalTransportEvent>(maxHistory: 64)
        var live = Live(
            transport: transport,
            metadata: metadata,
            configuration: configuration,
            isRunning: true,
            processId: info.processId,
            pump: nil,
            viewportPlainText: "",
            bytesReceived: 0,
            viewportGeneration: 0,
            lastExitReason: nil,
            rawSpool: BoundedByteSpool(maxBytes: maxRawSpoolBytes, overflow: .dropOldest),
            onOutput: onOutput,
            eventHub: hub
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
        let c = Int(TerminalDimension.clampCells(cols))
        let r = Int(TerminalDimension.clampCells(rows))
        try await live.transport.resize(cols: c, rows: r, widthPx: 0, heightPx: 0)
        live.configuration.cols = c
        live.configuration.rows = r
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

    /// Host updates viewport from Ghostty formatter/snapshot (TER-N05/N06).
    /// Never pass process-chunk-decoded strings here.
    public func updateViewport(
        plainText: String,
        generation: UInt64,
        for id: TerminalSessionID
    ) {
        guard var live = sessions[id] else { return }
        // Only accept non-decreasing generation from Ghostty dirty counter.
        if generation >= live.viewportGeneration {
            live.viewportPlainText = plainText
            live.viewportGeneration = generation
            sessions[id] = live
        }
    }

    /// Compatibility shim for older callers — routes to `updateViewport`.
    public func updateSnapshot(_ text: String, for id: TerminalSessionID) {
        let gen = (sessions[id]?.viewportGeneration ?? 0) &+ 1
        updateViewport(plainText: text, generation: gen, for: id)
    }

    /// Paged read of raw spool for diagnostics/search (TER-N06) — not full-string poll.
    public func readScrollbackPage(
        session id: TerminalSessionID,
        offset: UInt64,
        maxBytes: Int
    ) async -> ScrollbackPage? {
        guard let live = sessions[id] else { return nil }
        let view = await live.rawSpool.read(from: offset, maxBytes: max(0, maxBytes))
        return ScrollbackPage(
            absoluteOffset: view.absoluteOffset,
            data: view.data,
            leadingTruncated: view.leadingTruncated,
            availableStart: view.availableStart,
            availableEnd: view.availableEnd
        )
    }

    public func subscribe(
        session id: TerminalSessionID
    ) async -> AsyncStream<AsyncBroadcastHub<TerminalTransportEvent>.Envelope>? {
        guard let live = sessions[id] else { return nil }
        return await live.eventHub.subscribeEnvelopes()
    }

    // MARK: - Private

    private func handle(_ event: TerminalTransportEvent, session id: TerminalSessionID) async {
        guard var live = sessions[id] else { return }
        await live.eventHub.publish(event)
        switch event {
        case .output(let data):
            // TER-N05: feed raw bytes only — never String(data:encoding:).
            live.bytesReceived &+= UInt64(data.count)
            _ = await live.rawSpool.append(data)
            if let onOutput = live.onOutput {
                await onOutput(data)
            }
            sessions[id] = live
        case .terminated(let reason):
            live.isRunning = false
            live.lastExitReason = reason
            sessions[id] = live
            await live.eventHub.finish(.completed)
        case .overflowTerminated(let msg):
            live.isRunning = false
            live.lastExitReason = .spawnFailed(msg)
            sessions[id] = live
            await live.eventHub.finish(.completed)
        case .error:
            sessions[id] = live
        }
    }
}

extension AsyncBroadcastHub where Event == TerminalTransportEvent {
    fileprivate func subscribeEnvelopes() async -> AsyncStream<Envelope> {
        let stream = self.subscribe(
            policy: .dropOldest(capacity: 64, emitGap: true),
            replay: .none
        )
        return AsyncStream { continuation in
            let task = Task {
                for await item in stream {
                    switch item {
                    case .value(let env):
                        continuation.yield(env)
                    case .gap:
                        continue
                    case .finished:
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
