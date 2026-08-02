import CodeEditorCore
import Darwin
import Foundation

public protocol TerminalBackend: Sendable {
    func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle
    func write(_ data: Data, to session: TerminalSessionID) async throws
    func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws
    func terminate(session: TerminalSessionID) async
    var output: AsyncStream<TerminalOutputEvent> { get }
}

/// In-memory backend for tests (echoes writes).
public actor MockTerminalBackend: TerminalBackend {
    private var sessions: Set<TerminalSessionID> = []
    private var continuation: AsyncStream<TerminalOutputEvent>.Continuation?
    public let output: AsyncStream<TerminalOutputEvent>

    public init() {
        var cont: AsyncStream<TerminalOutputEvent>.Continuation!
        self.output = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle {
        _ = configuration
        let handle = TerminalSessionHandle()
        sessions.insert(handle.id)
        return handle
    }

    public func write(_ data: Data, to session: TerminalSessionID) async throws {
        guard sessions.contains(session) else { throw TerminalError.sessionNotFound }
        continuation?.yield(.data(session: session, bytes: data))
    }

    public func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws {
        _ = cols
        _ = rows
        guard sessions.contains(session) else { throw TerminalError.sessionNotFound }
    }

    public func terminate(session: TerminalSessionID) async {
        sessions.remove(session)
        continuation?.yield(.exited(session: session, code: 0))
    }
}

/// Legacy process-pipe backend (not a PTY). Prefer ``PTYTerminalBackend`` on macOS.
/// Kept for hosts that only grant `localProcess` without PTY.
public actor ProcessTerminalBackend: TerminalBackend {
    private struct Entry {
        var process: Process
        var stdin: Pipe
    }

    private var entries: [TerminalSessionID: Entry] = [:]
    private var continuation: AsyncStream<TerminalOutputEvent>.Continuation?
    public let output: AsyncStream<TerminalOutputEvent>
    public let platformProfile: PlatformCapabilityProfile

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
        var cont: AsyncStream<TerminalOutputEvent>.Continuation!
        self.output = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle {
        try platformProfile.requireLocal(.localProcess)
        let handle = TerminalSessionHandle()
        let process = Process()
        let shell = configuration.shell ?? URL(fileURLWithPath: "/bin/sh")
        process.executableURL = shell
        process.arguments = configuration.arguments
        if let cwd = configuration.cwd {
            process.currentDirectoryURL = cwd
        }
        if !configuration.environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in configuration.environment { env[k] = v }
            process.environment = env
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        do {
            try process.run()
        } catch {
            throw TerminalError.startFailed(String(describing: error))
        }
        let pid = process.processIdentifier
        if pid > 0 { _ = setpgid(pid, pid) }
        entries[handle.id] = Entry(process: process, stdin: stdin)

        let sessionID = handle.id
        let cont = continuation
        stdout.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                cont?.yield(.exited(session: sessionID, code: process.terminationStatus))
                return
            }
            cont?.yield(.data(session: sessionID, bytes: data))
        }
        return handle
    }

    public func write(_ data: Data, to session: TerminalSessionID) async throws {
        guard let entry = entries[session] else { throw TerminalError.sessionNotFound }
        try entry.stdin.fileHandleForWriting.write(contentsOf: data)
    }

    public func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws {
        _ = cols
        _ = rows
        guard entries[session] != nil else { throw TerminalError.sessionNotFound }
        // Not a PTY — resize is a no-op by design for the legacy pipe backend.
    }

    public func terminate(session: TerminalSessionID) async {
        if let entry = entries.removeValue(forKey: session) {
            let pid = entry.process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGTERM)
            }
            entry.process.terminate()
            continuation?.yield(.exited(session: session, code: entry.process.terminationStatus))
        }
    }
}
