import CodeEditorCore
import Foundation

/// Host/remote transport events beyond raw bytes.
public enum RemoteTerminalEvent: Sendable, Hashable {
    case data(Data)
    case disconnected(reason: String)
    case reconnected
    case exited(code: Int32)
}

/// Contract for SSH/WebSocket/host-provided terminal transports (iOS path).
public protocol RemoteTerminalTransport: Sendable {
    func connect(configuration: TerminalConfiguration) async throws
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func disconnect() async
    var events: AsyncStream<RemoteTerminalEvent> { get }
}

/// Terminal backend that wraps a ``RemoteTerminalTransport``.
public actor RemoteTerminalBackend: TerminalBackend {
    private var transports: [TerminalSessionID: any RemoteTerminalTransport] = [:]
    private var factories: [TerminalSessionID: @Sendable () -> any RemoteTerminalTransport] = [:]
    private var continuation: AsyncStream<TerminalOutputEvent>.Continuation?
    public let output: AsyncStream<TerminalOutputEvent>
    public let platformProfile: PlatformCapabilityProfile
    private let transportFactory: @Sendable () -> any RemoteTerminalTransport

    public init(
        platformProfile: PlatformCapabilityProfile = .default(),
        transportFactory: @escaping @Sendable () -> any RemoteTerminalTransport
    ) {
        self.platformProfile = platformProfile
        self.transportFactory = transportFactory
        var cont: AsyncStream<TerminalOutputEvent>.Continuation!
        self.output = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle {
        // Remote path does not require localPTY; may require network if host says so.
        let handle = TerminalSessionHandle()
        let transport = transportFactory()
        try await transport.connect(configuration: configuration)
        transports[handle.id] = transport
        let sessionID = handle.id
        let cont = continuation
        Task {
            for await event in transport.events {
                switch event {
                case .data(let data):
                    cont?.yield(.data(session: sessionID, bytes: data))
                case .disconnected(let reason):
                    cont?.yield(.data(session: sessionID, bytes: Data("\r\n[disconnected: \(reason)]\r\n".utf8)))
                case .reconnected:
                    cont?.yield(.data(session: sessionID, bytes: Data("\r\n[reconnected]\r\n".utf8)))
                case .exited(let code):
                    cont?.yield(.exited(session: sessionID, code: code))
                }
            }
        }
        return handle
    }

    public func write(_ data: Data, to session: TerminalSessionID) async throws {
        guard let t = transports[session] else { throw TerminalError.sessionNotFound }
        try await t.write(data)
    }

    public func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws {
        guard let t = transports[session] else { throw TerminalError.sessionNotFound }
        try await t.resize(cols: cols, rows: rows)
    }

    public func terminate(session: TerminalSessionID) async {
        if let t = transports.removeValue(forKey: session) {
            await t.disconnect()
            continuation?.yield(.exited(session: session, code: 0))
        }
    }
}

/// In-memory remote transport for tests (echo + disconnect simulation).
public actor MockRemoteTerminalTransport: RemoteTerminalTransport {
    private var cont: AsyncStream<RemoteTerminalEvent>.Continuation?
    public let events: AsyncStream<RemoteTerminalEvent>
    public private(set) var connected = false
    public private(set) var lastResize: (Int, Int)?
    public var echo = true

    public init() {
        var c: AsyncStream<RemoteTerminalEvent>.Continuation!
        self.events = AsyncStream { c = $0 }
        self.cont = c
    }

    public func connect(configuration: TerminalConfiguration) async throws {
        _ = configuration
        connected = true
    }

    public func write(_ data: Data) async throws {
        guard connected else { throw TerminalError.notRunning }
        if echo {
            cont?.yield(.data(data))
        }
    }

    public func resize(cols: Int, rows: Int) async throws {
        lastResize = (cols, rows)
    }

    public func disconnect() async {
        connected = false
        cont?.yield(.disconnected(reason: "closed"))
        cont?.finish()
    }

    public func simulateDisconnect(reason: String = "network") {
        connected = false
        cont?.yield(.disconnected(reason: reason))
    }

    public func simulateReconnect() {
        connected = true
        cont?.yield(.reconnected)
    }
}
