import CodeEditorCore
import CodeEditorTerminal
import Foundation

/// In-memory remote transport for tests (echo + disconnect simulation).
/// Lives under Tests/ only — not production API (REL-N08).
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
