import Foundation
import Darwin
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

    private let stderrPipe: Pipe
    private var stderrTask: Task<Void, Never>?
    private let stderrLock = NSLock()
    private var _stderrBytes = Data()
    public let maxStderrBytes: Int

    public var stderrBytes: Data {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return _stderrBytes
    }

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        platformProfile: PlatformCapabilityProfile = .default(),
        maxStderrBytes: Int = 64 * 1024
    ) throws {
        try platformProfile.requireLocal(.localLanguageServerProcess)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // New process group so shutdown can kill descendants.
        process.qualityOfService = .userInitiated
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.maxStderrBytes = max(1024, maxStderrBytes)

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont

        try process.run()
        // Best-effort: put the server in its own process group so kill(-pid) reaps children.
        let pid = process.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
        }

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
        let errHandle = stderr.fileHandleForReading
        let cap = self.maxStderrBytes
        stderrTask = Task { [weak self] in
            while !Task.isCancelled {
                let data = errHandle.availableData
                if data.isEmpty { break }
                guard let self else { break }
                self.appendStderr(data, cap: cap)
            }
        }
    }

    private func appendStderr(_ data: Data, cap: Int) {
        stderrLock.lock()
        _stderrBytes.append(data)
        if _stderrBytes.count > cap {
            _stderrBytes = Data(_stderrBytes.suffix(cap))
        }
        stderrLock.unlock()
    }

    public func send(_ data: Data) async throws {
        let closed = state.withLock { $0.closed }
        if closed { throw LSPError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Terminates the process group (parent + children) when possible.
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
        stderrTask?.cancel()
        cont?.finish()
        try? stdinPipe.fileHandleForWriting.close()
        killProcessGroup()
    }

    private func killProcessGroup() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            // Negative PID targets the process group.
            kill(-pid, SIGTERM)
            // Brief grace then SIGKILL.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [process] in
                if process.isRunning {
                    kill(-pid, SIGKILL)
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }
        } else {
            process.terminate()
        }
    }
}
