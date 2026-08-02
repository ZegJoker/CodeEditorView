import Foundation
import CodeEditorDAP

/// In-process duplex pair for DAP unit tests (test support only; not production).
public final class DAPTestTransport: DAPTransport, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var closed = false
        weak var peer: DAPTestTransport?
        var continuation: AsyncStream<Data>.Continuation?

        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    private let state = State()
    public let inbound: AsyncStream<Data>

    public init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont
    }

    public static func makePair() -> (client: DAPTestTransport, server: DAPTestTransport) {
        let a = DAPTestTransport()
        let b = DAPTestTransport()
        a.state.withLock { $0.peer = b }
        b.state.withLock { $0.peer = a }
        return (a, b)
    }

    public func send(_ data: Data) async throws {
        let (closed, peer) = state.withLock { ($0.closed, $0.peer) }
        if closed { throw DAPError.transportClosed }
        guard let peer else { throw DAPError.transportClosed }
        peer.receive(data)
    }

    private func receive(_ data: Data) {
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            s.closed ? nil : s.continuation
        }
        cont?.yield(data)
    }

    public func close() async {
        let (cont, peer) = state.withLock { s -> (AsyncStream<Data>.Continuation?, DAPTestTransport?) in
            s.closed = true
            let c = s.continuation
            s.continuation = nil
            let p = s.peer
            s.peer = nil
            return (c, p)
        }
        cont?.finish()
        if let peer { await peer.finishInbound() }
    }

    private func finishInbound() async {
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            s.closed = true
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.finish()
    }
}
