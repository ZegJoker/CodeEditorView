import CodeEditorCore
import Darwin
import Foundation

#if canImport(CGhosttyShim)
    import CGhosttyShim
#endif

/// macOS local PTY transport using C `ce_pty_spawn` (no Swift in child) — TER-002/003.
public actor LocalPTYTransport: TerminalByteTransport {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingWrite = Data()
    private var cont: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation?
    private var finished = false
    public let events: AsyncThrowingStream<TerminalTransportEvent, Error>
    public let platformProfile: PlatformCapabilityProfile
    public let securityPolicy: TerminalSecurityPolicy

    public init(
        platformProfile: PlatformCapabilityProfile = .default(),
        securityPolicy: TerminalSecurityPolicy = .restricted
    ) {
        self.platformProfile = platformProfile
        self.securityPolicy = securityPolicy
        var c: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { c = $0 }
        self.cont = c
    }

    public func start(_ request: TerminalLaunchRequest) async throws -> TerminalProcessInfo {
        try platformProfile.requireLocal(.localPTY)
        guard securityPolicy.allowLocalPTY else {
            throw TerminalError.startFailed("local PTY denied by security policy")
        }
        #if os(macOS) && canImport(CGhosttyShim)
            let cfg = request.configuration
            let shellPath = cfg.shell?.path ?? "/bin/zsh"
            let argList = [shellPath] + cfg.arguments
            var cArgv: [UnsafeMutablePointer<CChar>?] = argList.map { strdup($0) }
            cArgv.append(nil)
            defer { for p in cArgv where p != nil { free(p) } }

            var env = ProcessInfo.processInfo.environment
            for (k, v) in cfg.environment { env[k] = v }
            env["TERM"] = env["TERM"] ?? "xterm-256color"
            var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
            cEnv.append(nil)
            defer { for p in cEnv where p != nil { free(p) } }

            let rows = UInt16(max(1, cfg.rows))
            let cols = UInt16(max(1, cfg.cols))
            let result: ce_pty_spawn_result
            if let cwd = cfg.cwd?.path {
                result = shellPath.withCString { sh in
                    cwd.withCString { cd in
                        ce_pty_spawn(sh, &cArgv, cd, &cEnv, rows, cols)
                    }
                }
            } else {
                result = shellPath.withCString { sh in
                    ce_pty_spawn(sh, &cArgv, nil, &cEnv, rows, cols)
                }
            }

            if result.error != 0 || result.master_fd < 0 || result.child_pid <= 0 {
                throw TerminalError.startFailed("ce_pty_spawn failed: \(result.error)")
            }

            masterFD = result.master_fd
            childPID = result.child_pid
            let flags = fcntl(masterFD, F_GETFL)
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
            installReadSource()
            return TerminalProcessInfo(processId: result.child_pid, masterFD: result.master_fd)
        #else
            throw TerminalError.startFailed("Local PTY requires macOS + CGhosttyShim")
        #endif
    }

    public func write(_ bytes: Data) async throws {
        guard masterFD >= 0 else { throw TerminalError.notRunning }
        pendingWrite.append(bytes)
        try await flushPendingWrite()
    }

    public func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) async throws {
        _ = (widthPx, heightPx)
        guard masterFD >= 0 else { throw TerminalError.sessionNotFound }
        #if canImport(CGhosttyShim)
            if ce_pty_resize(masterFD, UInt16(max(1, rows)), UInt16(max(1, cols))) != 0 {
                throw TerminalError.startFailed("ce_pty_resize failed")
            }
        #endif
    }

    public func terminate(_ reason: TerminalTerminationReason) async {
        _ = reason
        guard !finished else { return }
        finished = true
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        let fd = masterFD
        let pid = childPID
        masterFD = -1
        childPID = -1
        #if canImport(CGhosttyShim)
            _ = ce_pty_terminate(fd, pid)
        #else
            if fd >= 0 { close(fd) }
            if pid > 0 {
                kill(-pid, SIGTERM)
                waitpid(pid, nil, 0)
            }
        #endif
        cont?.yield(.exited(code: 0))
        cont?.finish()
        cont = nil
    }

    private func installReadSource() {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleReadable() }
        }
        readSource = source
        source.resume()
    }

    private func handleReadable() async {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                cont?.yield(.output(Data(buffer.prefix(n))))
                continue
            }
            if n == 0 {
                await finishExited()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            cont?.yield(.error("read failed: \(errno)"))
            await finishExited()
            return
        }
    }

    private func finishExited() async {
        guard !finished else { return }
        finished = true
        var status: Int32 = 0
        if childPID > 0 {
            waitpid(childPID, &status, 0)
        }
        let code: Int32 = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : -1
        let fd = masterFD
        masterFD = -1
        childPID = -1
        readSource?.cancel()
        readSource = nil
        if fd >= 0 { close(fd) }
        cont?.yield(.exited(code: code))
        cont?.finish()
        cont = nil
    }

    private func flushPendingWrite() async throws {
        guard masterFD >= 0 else { return }
        while !pendingWrite.isEmpty {
            let chunk = pendingWrite
            let n: Int = chunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.write(masterFD, base, chunk.count)
            }
            if n > 0 {
                pendingWrite.removeFirst(n)
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try await waitWritable()
                continue
            }
            if n < 0 {
                throw TerminalError.startFailed("write failed: \(errno)")
            }
            break
        }
    }

    private func waitWritable() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let fd = masterFD
            guard fd >= 0 else {
                continuation.resume(throwing: TerminalError.notRunning)
                return
            }
            let source = DispatchSource.makeWriteSource(
                fileDescriptor: fd, queue: .global(qos: .userInteractive))
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            writeSource = source
            source.resume()
        }
    }
}
