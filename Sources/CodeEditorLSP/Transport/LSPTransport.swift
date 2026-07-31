import Foundation
import CodeEditorCore

/// Duplex raw-byte transport; framing is applied by ``LSPJSONRPCConnection``.
public protocol LSPTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

/// Shared mutable state for transports (locks only used from synchronous methods).
private final class TransportState: @unchecked Sendable {
    private let lock = NSLock()
    var closed = false
    var peer: LSPTestTransport?
    var continuation: AsyncStream<Data>.Continuation?

    func withLock<T>(_ body: (TransportState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// In-process duplex pipe pair for tests and mock servers.
public final class LSPTestTransport: LSPTransport, @unchecked Sendable {
    private let state = TransportState()
    public let inbound: AsyncStream<Data>

    public init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont
    }

    /// Creates a connected client/server pair.
    public static func makePair() -> (client: LSPTestTransport, server: LSPTestTransport) {
        let a = LSPTestTransport()
        let b = LSPTestTransport()
        a.state.withLock { $0.peer = b }
        b.state.withLock { $0.peer = a }
        return (a, b)
    }

    public func send(_ data: Data) async throws {
        let (closed, peer) = state.withLock { ($0.closed, $0.peer) }
        if closed { throw LSPError.transportClosed }
        guard let peer else { throw LSPError.transportClosed }
        peer.receive(data)
    }

    private func receive(_ data: Data) {
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            s.closed ? nil : s.continuation
        }
        cont?.yield(data)
    }

    public func close() async {
        let (cont, peer) = state.withLock { s -> (AsyncStream<Data>.Continuation?, LSPTestTransport?) in
            s.closed = true
            let c = s.continuation
            s.continuation = nil
            let p = s.peer
            s.peer = nil
            return (c, p)
        }
        cont?.finish()
        if let peer {
            await peer.finishInbound()
        }
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

/// Stdio process transport (local language server).
public final class LSPProcessTransport: LSPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let state = TransportState()
    public let inbound: AsyncStream<Data>
    private var readerTask: Task<Void, Never>?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        platformProfile: PlatformCapabilityProfile = .default()
    ) throws {
        try platformProfile.requireLocal(.localLanguageServerProcess)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont

        try process.run()

        let handle = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty {
                    await self?.close()
                    break
                }
                self?.state.withLock { $0.continuation }?.yield(data)
            }
        }
    }

    public func send(_ data: Data) async throws {
        let closed = state.withLock { $0.closed }
        if closed { throw LSPError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        let already = state.withLock { s -> Bool in
            if s.closed { return true }
            s.closed = true
            return false
        }
        if already { return }
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        readerTask?.cancel()
        cont?.finish()
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }
}
