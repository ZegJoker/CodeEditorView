import CodeEditorCore
import Darwin
import Foundation

#if canImport(CGhosttyShim)
    import CGhosttyShim
#endif

/// macOS local PTY transport owned with ``ProcessSupervisor`` lifecycle (TER-N07).
///
/// - Atomic spawn/session setup via `ce_pty_spawn`
/// - Serialized bounded writes (single write pump; no concurrent source overwrite)
/// - Raw-byte multicast output via ``AsyncBroadcastHub``
/// - Nonblocking cancel/escalation
/// - Exact exit reason (exited / signalled / cancelled / spawnFailed)
/// - Validated/clamped dimensions + resize coalescing
/// - Optional registration with a shared ``ProcessSupervisor``
public actor LocalPTYTransport: TerminalByteTransport {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var writeInFlight = false
    private var finished = false
    private var cancelRequested = false
    private var lastExit: TerminalProcessExitReason?
    private var pendingResize: (cols: UInt16, rows: UInt16)?
    private var resizeTask: Task<Void, Never>?
    private var exitWaiters: [CheckedContinuation<TerminalProcessExitReason, Never>] = []
    private var ptyLeaseID: PTYLeaseID?

    private let hub = AsyncBroadcastHub<TerminalTransportEvent>(maxHistory: 128)
    private let inboundSpool: BoundedByteSpool
    private let writeQueue: TerminalOutboundWriteQueue
    private let maxInboundBytes: Int
    private let maxWriteQueueBytes: Int
    private let supervisor: ProcessSupervisor?

    public let platformProfile: PlatformCapabilityProfile
    public let securityPolicy: TerminalSecurityPolicy

    /// Primary event stream (also multicast via ``makeEventStream``).
    public let events: AsyncThrowingStream<TerminalTransportEvent, Error>

    private var streamContinuation: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation?

    public init(
        platformProfile: PlatformCapabilityProfile = .default(),
        securityPolicy: TerminalSecurityPolicy = .restricted,
        maxInboundBytes: Int = 16 * 1024 * 1024,
        maxWriteQueueBytes: Int = 4 * 1024 * 1024,
        supervisor: ProcessSupervisor? = nil
    ) {
        self.platformProfile = platformProfile
        self.securityPolicy = securityPolicy
        self.maxInboundBytes = max(64 * 1024, maxInboundBytes)
        self.maxWriteQueueBytes = max(64 * 1024, maxWriteQueueBytes)
        self.supervisor = supervisor
        self.inboundSpool = BoundedByteSpool(maxBytes: self.maxInboundBytes, overflow: .rejectNewest)
        self.writeQueue = TerminalOutboundWriteQueue(maxBytes: self.maxWriteQueueBytes)
        var c: AsyncThrowingStream<TerminalTransportEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { c = $0 }
        self.streamContinuation = c
    }

    /// Bound for outbound write queue (TER-N07).
    public var writeQueueCapacity: Int { maxWriteQueueBytes }

    /// Current queued outbound bytes (TER-N07).
    public func queuedWriteBytes() async -> Int {
        await writeQueue.queuedBytes
    }

    /// Additional multicast subscriber (TER-N07 raw-byte multicast).
    public func makeEventStream(
        capacity: Int = 64
    ) async -> AsyncStream<TerminalTransportEvent> {
        let stream = await hub.subscribe(
            policy: .dropOldest(capacity: max(1, capacity), emitGap: true),
            replay: .allBuffered
        )
        return AsyncStream { continuation in
            let task = Task {
                for await item in stream {
                    switch item {
                    case .value(let env):
                        continuation.yield(env.event)
                    case .gap:
                        continuation.yield(.error("event gap"))
                    case .finished:
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

            let rows = TerminalDimension.clampCells(cfg.rows)
            let cols = TerminalDimension.clampCells(cfg.cols)
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
                let msg = "ce_pty_spawn failed: \(result.error)"
                await publish(.terminated(.spawnFailed(msg)))
                throw TerminalError.startFailed(msg)
            }

            // Validate descriptor is open and non-blocking.
            let flags = fcntl(result.master_fd, F_GETFL)
            if flags < 0 {
                _ = ce_pty_terminate(result.master_fd, result.child_pid)
                let msg = "fcntl F_GETFL failed: \(errno)"
                await publish(.terminated(.spawnFailed(msg)))
                throw TerminalError.startFailed(msg)
            }
            if fcntl(result.master_fd, F_SETFL, flags | O_NONBLOCK) < 0 {
                _ = ce_pty_terminate(result.master_fd, result.child_pid)
                let msg = "fcntl F_SETFL failed: \(errno)"
                await publish(.terminated(.spawnFailed(msg)))
                throw TerminalError.startFailed(msg)
            }

            masterFD = result.master_fd
            childPID = result.child_pid
            installReadSource()
            if let supervisor {
                let lease = await supervisor.registerPTY(
                    PTYSessionCallbacks(
                        cancel: { [weak self] in
                            await self?.terminate(.user)
                        },
                        awaitExit: { [weak self] in
                            guard let self else { return .cancelled }
                            let reason = await self.awaitExitReason()
                            return Self.mapSupervised(reason)
                        }
                    )
                )
                ptyLeaseID = lease
            }
            return TerminalProcessInfo(processId: result.child_pid, masterFD: result.master_fd)
        #else
            let msg = "Local PTY requires macOS + CGhosttyShim"
            await publish(.terminated(.spawnFailed(msg)))
            throw TerminalError.startFailed(msg)
        #endif
    }

    /// Wait until the PTY session has an exact exit reason (TER-N07).
    public func awaitExitReason() async -> TerminalProcessExitReason {
        if let lastExit { return lastExit }
        return await withCheckedContinuation { cont in
            exitWaiters.append(cont)
        }
    }

    public var registeredPTYLeaseID: PTYLeaseID? { ptyLeaseID }

    private static func mapSupervised(_ reason: TerminalProcessExitReason) -> SupervisedExitReason {
        switch reason {
        case .exited(let code): return .exited(code: code)
        case .signalled(let signal): return .signalled(signal: signal)
        case .cancelled: return .cancelled
        case .spawnFailed(let msg): return .spawnFailed(msg)
        }
    }

    public func write(_ bytes: Data) async throws {
        guard masterFD >= 0, !finished else { throw TerminalError.notRunning }
        // Actor isolation serializes concurrent writers; queue fails closed on overflow (TER-N07).
        try await writeQueue.enqueue(bytes)
        try await flushPendingWrite()
    }

    public func resize(cols: Int, rows: Int, widthPx: Int, heightPx: Int) async throws {
        _ = (widthPx, heightPx)
        guard masterFD >= 0 else { throw TerminalError.sessionNotFound }
        let c = TerminalDimension.clampCells(cols)
        let r = TerminalDimension.clampCells(rows)
        // Coalesce rapid resizes (TER-N07).
        pendingResize = (c, r)
        if resizeTask == nil {
            resizeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000)
                await self?.applyPendingResize()
            }
        }
    }

    public func terminate(_ reason: TerminalTerminationReason) async {
        guard !finished else { return }
        cancelRequested = (reason == .user || reason == .replaced)
        finished = true
        readSource?.cancel()
        readSource = nil
        cancelWriteWait(error: TerminalError.notRunning)
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
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        #endif
        let exitReason: TerminalProcessExitReason
        switch reason {
        case .user, .replaced:
            exitReason = .cancelled
        case .processExited:
            exitReason = .exited(code: 0)
        case .error(let msg):
            exitReason = .spawnFailed(msg)
        }
        lastExit = exitReason
        resumeExitWaiters(exitReason)
        await publish(.terminated(exitReason))
        streamContinuation?.finish()
        streamContinuation = nil
        await hub.finish(.completed)
    }

    public var lastExitReason: TerminalProcessExitReason? { lastExit }

    private func resumeExitWaiters(_ reason: TerminalProcessExitReason) {
        let waiters = exitWaiters
        exitWaiters.removeAll()
        for w in waiters { w.resume(returning: reason) }
    }

    // MARK: - Private

    private func applyPendingResize() async {
        resizeTask = nil
        guard let pending = pendingResize, masterFD >= 0 else { return }
        pendingResize = nil
        #if canImport(CGhosttyShim)
            if ce_pty_resize(masterFD, pending.rows, pending.cols) != 0 {
                await publish(.error("ce_pty_resize failed: \(errno)"))
            }
        #endif
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
        guard masterFD >= 0, !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(masterFD, &buffer, buffer.count)
            if n > 0 {
                let chunk = Data(buffer.prefix(n))
                let result = await inboundSpool.append(chunk)
                if result.truncated && result.acceptedBytes == 0 {
                    await publish(.overflowTerminated("inbound PTY spool full (\(maxInboundBytes) bytes)"))
                    await finishNatural(exitHint: nil)
                    return
                }
                if result.acceptedBytes > 0 {
                    let accepted = Data(chunk.prefix(result.acceptedBytes))
                    await publish(.output(accepted))
                }
                continue
            }
            if n == 0 {
                await finishNatural(exitHint: nil)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            await publish(.error("read failed: \(errno)"))
            await finishNatural(exitHint: nil)
            return
        }
    }

    private func finishNatural(exitHint: TerminalProcessExitReason?) async {
        guard !finished else { return }
        finished = true
        var status: Int32 = 0
        var reason: TerminalProcessExitReason
        if let exitHint {
            reason = exitHint
        } else if cancelRequested {
            reason = .cancelled
        } else if childPID > 0 {
            let w = waitpid(childPID, &status, 0)
            if w > 0 {
                if (status & 0x7f) == 0 {
                    reason = .exited(code: (status >> 8) & 0xff)
                } else if (status & 0x7f) != 0x7f {
                    reason = .signalled(signal: status & 0x7f)
                } else {
                    reason = .exited(code: -1)
                }
            } else {
                reason = .exited(code: -1)
            }
        } else {
            reason = .exited(code: -1)
        }
        let fd = masterFD
        masterFD = -1
        childPID = -1
        readSource?.cancel()
        readSource = nil
        cancelWriteWait(error: TerminalError.notRunning)
        if fd >= 0 { close(fd) }
        lastExit = reason
        resumeExitWaiters(reason)
        await publish(.terminated(reason))
        streamContinuation?.finish()
        streamContinuation = nil
        await hub.finish(.completed)
    }

    private func publish(_ event: TerminalTransportEvent) async {
        streamContinuation?.yield(event)
        await hub.publish(event)
    }

    private func flushPendingWrite() async throws {
        guard masterFD >= 0 else { return }
        while await writeQueue.queuedBytes > 0 {
            let chunk = await writeQueue.take(maxChunk: 64 * 1024)
            if chunk.isEmpty { break }
            var remaining = chunk
            while !remaining.isEmpty {
                let n: Int = remaining.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return Darwin.write(masterFD, base, remaining.count)
                }
                if n > 0 {
                    remaining.removeFirst(n)
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Re-queue unwritten tail before waiting.
                    try await writeQueue.enqueue(remaining)
                    try await waitWritable()
                    break
                }
                if n < 0 {
                    throw TerminalError.startFailed("write failed: \(errno)")
                }
                break
            }
        }
    }

    /// Single write-source waiter — concurrent callers serialize on the actor (TER-N07).
    private func waitWritable() async throws {
        if writeInFlight {
            // Another waiter already owns the source; poll briefly.
            try await Task.sleep(nanoseconds: 1_000_000)
            return
        }
        writeInFlight = true
        defer { writeInFlight = false }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let fd = masterFD
            guard fd >= 0 else {
                continuation.resume(throwing: TerminalError.notRunning)
                return
            }
            // Cancel any prior source before installing a new one.
            writeSource?.cancel()
            writeSource = nil
            writeContinuation = continuation
            let source = DispatchSource.makeWriteSource(
                fileDescriptor: fd, queue: .global(qos: .userInteractive))
            source.setEventHandler { [weak self] in
                source.cancel()
                Task { await self?.resumeWriteWait() }
            }
            source.setCancelHandler { [weak self] in
                Task { await self?.resumeWriteWait() }
            }
            writeSource = source
            source.resume()
        }
    }

    private func resumeWriteWait() {
        writeSource = nil
        if let c = writeContinuation {
            writeContinuation = nil
            c.resume()
        }
    }

    private func cancelWriteWait(error: Error) {
        writeSource?.cancel()
        writeSource = nil
        if let c = writeContinuation {
            writeContinuation = nil
            c.resume(throwing: error)
        }
    }
}
