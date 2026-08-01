import Foundation
import Darwin
import CodeEditorCore

#if os(macOS)
/// macOS PTY backend using `forkpty` with process-group teardown and window-size ioctl.
public final class PTYTerminalBackend: TerminalBackend, @unchecked Sendable {
    private struct Entry {
        var masterFD: Int32
        var childPID: pid_t
        var readSource: DispatchSourceRead?
    }

    private let lock = NSLock()
    private var entries: [TerminalSessionID: Entry] = [:]
    private var continuation: AsyncStream<TerminalOutputEvent>.Continuation?
    public let output: AsyncStream<TerminalOutputEvent>
    public let platformProfile: PlatformCapabilityProfile

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
        var cont: AsyncStream<TerminalOutputEvent>.Continuation!
        // TER-001: never use lossy buffering for terminal bytes. Unbounded buffer with
        // backpressure at the PTY read side — dropping chunks corrupts VT state permanently.
        // `.unbounded` is the honest interim until Ghostty-owned transport; producers must
        // not silently discard. A full Ghostty migration replaces this path.
        self.output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    public func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle {
        try platformProfile.requireLocal(.localPTY)
        let handle = TerminalSessionHandle()

        var winsize = winsize(
            ws_row: UInt16(max(1, configuration.rows)),
            ws_col: UInt16(max(1, configuration.cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &winsize)
        if pid < 0 {
            throw TerminalError.startFailed("forkpty failed: \(errno)")
        }
        if pid == 0 {
            // Child
            if let cwd = configuration.cwd {
                _ = cwd.path.withCString { chdir($0) }
            }
            var env = ProcessInfo.processInfo.environment
            for (k, v) in configuration.environment { env[k] = v }
            env["TERM"] = env["TERM"] ?? "xterm-256color"
            let shell = configuration.shell?.path ?? "/bin/zsh"
            let args = [shell] + configuration.arguments
            // Build C argv
            let cArgs = args.map { strdup($0) } + [nil]
            defer { /* child exits via exec */ }
            for (k, v) in env {
                setenv(k, v, 1)
            }
            execvp(shell, cArgs.map { UnsafeMutablePointer($0) })
            _exit(127)
        }

        // Parent
        let sessionID = handle.id
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer.prefix(n))
                self?.continuation?.yield(.data(session: sessionID, bytes: data))
            } else {
                source.cancel()
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                // Darwin wait macros are unavailable in Swift; decode exit status manually.
                let code: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : -1
                self?.removeEntry(sessionID)
                self?.continuation?.yield(.exited(session: sessionID, code: code))
            }
        }
        source.setCancelHandler {
            close(master)
        }
        source.resume()

        storeEntry(sessionID, Entry(masterFD: master, childPID: pid, readSource: source))
        return handle
    }

    public func write(_ data: Data, to session: TerminalSessionID) async throws {
        guard let fd = masterFD(for: session) else { throw TerminalError.sessionNotFound }
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw TerminalError.startFailed("write failed: \(errno)")
                }
                written += n
            }
        }
    }

    public func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws {
        guard let fd = masterFD(for: session) else { throw TerminalError.sessionNotFound }
        var ws = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        if ioctl(fd, TIOCSWINSZ, &ws) != 0 {
            throw TerminalError.startFailed("TIOCSWINSZ failed: \(errno)")
        }
    }

    public func terminate(session: TerminalSessionID) async {
        guard let entry = removeEntry(session) else { return }
        entry.readSource?.cancel()
        if entry.childPID > 0 {
            kill(-entry.childPID, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                kill(-entry.childPID, SIGKILL)
            }
        }
        close(entry.masterFD)
        continuation?.yield(.exited(session: session, code: -1))
    }

    nonisolated private func storeEntry(_ session: TerminalSessionID, _ entry: Entry) {
        lock.lock()
        entries[session] = entry
        lock.unlock()
    }

    nonisolated private func masterFD(for session: TerminalSessionID) -> Int32? {
        lock.lock()
        let fd = entries[session]?.masterFD
        lock.unlock()
        return fd
    }

    nonisolated private func removeEntry(_ session: TerminalSessionID) -> Entry? {
        lock.lock()
        let entry = entries.removeValue(forKey: session)
        lock.unlock()
        return entry
    }
}
#else
/// Non-macOS stub: local PTY unavailable.
public final class PTYTerminalBackend: TerminalBackend, @unchecked Sendable {
    public let output: AsyncStream<TerminalOutputEvent>
    public let platformProfile: PlatformCapabilityProfile
    private var continuation: AsyncStream<TerminalOutputEvent>.Continuation?

    public init(platformProfile: PlatformCapabilityProfile = .default()) {
        self.platformProfile = platformProfile
        var cont: AsyncStream<TerminalOutputEvent>.Continuation!
        self.output = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start(configuration: TerminalConfiguration) async throws -> TerminalSessionHandle {
        _ = configuration
        try platformProfile.requireLocal(.localPTY)
        throw TerminalError.startFailed("PTY not available on this platform")
    }

    public func write(_ data: Data, to session: TerminalSessionID) async throws {
        _ = data; _ = session
        throw TerminalError.sessionNotFound
    }

    public func resize(cols: Int, rows: Int, session: TerminalSessionID) async throws {
        _ = cols; _ = rows; _ = session
        throw TerminalError.sessionNotFound
    }

    public func terminate(session: TerminalSessionID) async {
        _ = session
    }
}
#endif
