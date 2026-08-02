import CodeEditorCore
import Darwin
import Foundation

/// Duplex raw-byte transport; framing applied by ``DAPJSONRPCConnection``.
public protocol DAPTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

private final class DAPProcessTransportState: @unchecked Sendable {
    private let lock = NSLock()
    var closed = false
    var continuation: AsyncStream<Data>.Continuation?

    func withLock<T>(_ body: (DAPProcessTransportState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// TCP client transport for remote debug adapters (`.connect` launch mode).
public final class DAPTCPConnectTransport: DAPTransport, @unchecked Sendable {
    private let state = DAPProcessTransportState()
    public let inbound: AsyncStream<Data>
    private var input: InputStream?
    private var output: OutputStream?
    private var readerThread: Thread?
    private let host: String
    private let port: Int

    public init(host: String, port: Int, timeoutSeconds: TimeInterval = 5) throws {
        self.host = host
        self.port = port
        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { cont = $0 }
        state.continuation = cont

        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(
            kCFAllocatorDefault,
            host as CFString,
            UInt32(port),
            &readStream,
            &writeStream
        )
        guard let rs = readStream?.takeRetainedValue() as InputStream?,
            let ws = writeStream?.takeRetainedValue() as OutputStream?
        else {
            throw DAPError.transport("TCP connect failed to create streams for \(host):\(port)")
        }
        self.input = rs
        self.output = ws
        rs.open()
        ws.open()

        // Brief connect wait
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while rs.streamStatus == .opening || ws.streamStatus == .opening {
            if Date() > deadline {
                rs.close()
                ws.close()
                throw DAPError.transport("TCP connect timeout \(host):\(port)")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if rs.streamStatus == .error || ws.streamStatus == .error {
            rs.close()
            ws.close()
            throw DAPError.transport("TCP connect error \(host):\(port)")
        }

        let inputRef = rs
        let stateRef = state
        readerThread = Thread {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while !stateRef.withLock({ $0.closed }) {
                let n = inputRef.read(&buffer, maxLength: buffer.count)
                if n < 0 { break }
                if n == 0 {
                    if inputRef.streamStatus == .atEnd { break }
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                let data = Data(buffer[0..<n])
                let cont = stateRef.withLock { $0.closed ? nil : $0.continuation }
                cont?.yield(data)
            }
            let cont = stateRef.withLock { s -> AsyncStream<Data>.Continuation? in
                s.closed = true
                let c = s.continuation
                s.continuation = nil
                return c
            }
            cont?.finish()
        }
        readerThread?.name = "DAPTCPConnectTransport.reader"
        readerThread?.start()
    }

    public func send(_ data: Data) async throws {
        let closed = state.withLock { $0.closed }
        if closed { throw DAPError.transportClosed }
        guard let output else { throw DAPError.transportClosed }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw DAPError.transport("empty write")
            }
            var written = 0
            let total = data.count
            while written < total {
                let n = output.write(base.advanced(by: written), maxLength: total - written)
                if n <= 0 { throw DAPError.transport("TCP write failed") }
                written += n
            }
        }
    }

    public func close() async {
        let cont = state.withLock { s -> AsyncStream<Data>.Continuation? in
            if s.closed { return nil }
            s.closed = true
            let c = s.continuation
            s.continuation = nil
            return c
        }
        input?.close()
        output?.close()
        cont?.finish()
    }
}

/// Stdio process transport for local debug adapters.
public final class DAPProcessTransport: DAPTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let state = DAPProcessTransportState()
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
