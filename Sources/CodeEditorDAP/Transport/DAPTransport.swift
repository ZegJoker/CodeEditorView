import CodeEditorCore
import Darwin
import Foundation

/// Duplex raw-byte transport; framing applied by ``DAPJSONRPCConnection``.
public protocol DAPTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

private final class DAPTransportState: @unchecked Sendable {
    private let lock = NSLock()
    var closed = false
    var peer: DAPTestTransport?
    var continuation: AsyncStream<Data>.Continuation?

    func withLock<T>(_ body: (DAPTransportState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// In-process duplex pair for tests and mock adapters.
public final class DAPTestTransport: DAPTransport, @unchecked Sendable {
    private let state = DAPTransportState()
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

/// Stdio process transport for local debug adapters.
public final class DAPProcessTransport: DAPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let state = DAPTransportState()
    public let inbound: AsyncStream<Data>
    private var readerTask: Task<Void, Never>?
    private let stderrPipe: Pipe
    private var stderrTask: Task<Void, Never>?
    private let stderrBox = StderrBox()
    public let maxStderrBytes: Int

    public var stderrBytes: Data {
        stderrBox.snapshot()
    }

    private final class StderrBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data, max: Int) {
            lock.lock()
            data.append(chunk)
            if data.count > max { data = data.suffix(max) }
            lock.unlock()
        }
        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        platformProfile: PlatformCapabilityProfile = .default(),
        maxStderrBytes: Int = 64 * 1024
    ) throws {
        try platformProfile.requireLocal(.localLanguageServerProcess)
        self.maxStderrBytes = maxStderrBytes

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.qualityOfService = .userInitiated

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        try process.run()
        // Process group for descendant kill
        setpgid(process.processIdentifier, process.processIdentifier)

        readerTask = Task { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                guard let self else { break }
                let cont = self.state.withLock { $0.closed ? nil : $0.continuation }
                cont?.yield(data)
            }
            await self?.closeInbound()
        }
        let box = stderrBox
        let maxErr = maxStderrBytes
        stderrTask = Task {
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                box.append(data, max: maxErr)
            }
        }
    }

    public func send(_ data: Data) async throws {
        let closed = state.withLock { $0.closed }
        if closed { throw DAPError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        let already = state.withLock { s -> Bool in
            if s.closed { return true }
            s.closed = true
            return false
        }
        if already { return }
        readerTask?.cancel()
        stderrTask?.cancel()
        try? stdinPipe.fileHandleForWriting.close()
        let pid = process.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            try? await Task.sleep(nanoseconds: 100_000_000)
            kill(-pid, SIGKILL)
        }
        if process.isRunning { process.terminate() }
        await closeInbound()
    }

    private func closeInbound() async {
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            let c = s.continuation
            s.continuation = nil
            return c
        }
        cont?.finish()
    }
}
