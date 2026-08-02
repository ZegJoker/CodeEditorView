import CodeEditorCore
import Foundation

public protocol RemoteExtensionTransport: Sendable {
    func send(_ data: Data) async throws
    var inbound: AsyncStream<Data> { get }
    func close() async
}

private final class ProcessTransportState: @unchecked Sendable {
    private let lock = NSLock()
    var closed = false
    var continuation: AsyncStream<Data>.Continuation?

    func withLock<T>(_ body: (ProcessTransportState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }
}

/// Stdio child-process transport (macOS/Linux-friendly).
public final class ProcessRemoteExtensionTransport: RemoteExtensionTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let state = ProcessTransportState()
    public let inbound: AsyncStream<Data>
    private var readerTask: Task<Void, Never>?

    public init(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        platformProfile: PlatformCapabilityProfile = .default()
    ) throws {
        try platformProfile.requireLocal(.nativeExtensionProcess)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
        if state.withLock({ $0.closed }) { throw ExtensionHostError.transportClosed }
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
        if process.isRunning { process.terminate() }
    }
}
