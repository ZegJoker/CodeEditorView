import CodeEditorCore
import CodeEditorExtensionProtocol
import Darwin
import Foundation

/// Stdio transport that launches a helper in its own process group and kills all descendants on close.
public final class NativeHelperProcessTransport: ExtensionWireTransport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let lock = NSLock()
    private var closed = false
    public let inbound: AsyncStream<Data>
    private var continuation: AsyncStream<Data>.Continuation?
    private var readerTask: Task<Void, Never>?
    public private(set) var processIdentifier: Int32 = 0

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
        self.continuation = cont
        try process.run()
        processIdentifier = process.processIdentifier
        if processIdentifier > 0 {
            _ = setpgid(processIdentifier, processIdentifier)
        }
        let handle = stdout.fileHandleForReading
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty {
                    await self?.close()
                    break
                }
                self?.yield(data)
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func yield(_ data: Data) {
        let cont = withLock { closed ? nil : continuation }
        cont?.yield(data)
    }

    public func send(_ data: Data) async throws {
        if withLock({ closed }) { throw ExtensionWireError.transportClosed }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func close() async {
        let cont: AsyncStream<Data>.Continuation? = withLock {
            if closed { return nil }
            closed = true
            let c = continuation
            continuation = nil
            return c
        }
        guard cont != nil || process.isRunning else { return }
        readerTask?.cancel()
        cont?.finish()
        try? stdinPipe.fileHandleForWriting.close()
        terminateProcessGroup()
    }

    /// TERM process group, then KILL after grace — all descendants.
    public func terminateProcessGroup() {
        let pid = process.processIdentifier
        guard pid > 0 else {
            if process.isRunning { process.terminate() }
            return
        }
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(0.4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(-pid, SIGKILL)
            if process.isRunning { process.terminate() }
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Returns false if process (and ideally group) is gone.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}

