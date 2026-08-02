import Darwin
import Foundation

// MARK: - Process launch configuration

public enum ProcessLaunchMode: Sendable, Hashable {
    /// Execute `executable` with raw `arguments` (no shell).
    case direct
    /// Run via `/bin/sh -c` with POSIX shell quoting of argv.
    /// Requires ``PlatformCapabilityKind/localShellExecution`` (CORE-N04).
    case shell
}

public struct ProcessLaunchRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var mode: ProcessLaunchMode
    public var currentDirectory: URL?
    public var environment: [String: String]
    /// When true, merge `environment` over the current process environment.
    public var mergeEnvironment: Bool
    public var timeout: Duration?
    public var maxStdoutBytes: Int
    public var maxStderrBytes: Int
    public var capabilityKind: PlatformCapabilityKind
    /// Per-subscriber event buffer (CORE-N02). Defaults to a bounded capacity.
    public var eventBufferCapacity: Int

    public init(
        executable: String,
        arguments: [String] = [],
        mode: ProcessLaunchMode = .direct,
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        mergeEnvironment: Bool = true,
        timeout: Duration? = nil,
        maxStdoutBytes: Int = 8 * 1024 * 1024,
        maxStderrBytes: Int = 2 * 1024 * 1024,
        capabilityKind: PlatformCapabilityKind = .localProcess,
        eventBufferCapacity: Int = 64
    ) {
        self.executable = executable
        self.arguments = arguments
        self.mode = mode
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.mergeEnvironment = mergeEnvironment
        self.timeout = timeout
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
        self.capabilityKind = capabilityKind
        self.eventBufferCapacity = max(1, eventBufferCapacity)
    }
}

public enum ProcessOutputEvent: Sendable, Hashable {
    case stdout(Data)
    case stderr(Data)
    /// Delivered payload was truncated/spooled past the configured bound (CORE-N02).
    case outputGap(stream: ProcessOutputStream, droppedBytes: Int)
    case exited(code: Int32, timedOut: Bool)
}

public enum ProcessOutputStream: String, Sendable, Hashable {
    case stdout
    case stderr
}

public struct ProcessExit: Sendable, Hashable {
    public var code: Int32
    public var timedOut: Bool
    public init(code: Int32, timedOut: Bool) {
        self.code = code
        self.timedOut = timedOut
    }
}

public enum ProcessServiceError: Error, Sendable, Equatable {
    case invalidWorkingDirectory(String)
    case launchFailed(String)
    case timedOut
    case cancelled
    case alreadyExited
    /// Foundation.Process is unavailable on this platform (e.g. iOS).
    case unavailableOnPlatform
    /// Shell mode requested without ``PlatformCapabilityKind/localShellExecution``.
    case shellCapabilityRequired
}

/// POSIX shell single-argument quoting for shell launch mode.
public enum ShellQuoting {
    public static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        // Prefer single quotes; escape embedded ' as '\''
        if argument.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)  // 0-9
                || (v >= 0x41 && v <= 0x5A)  // A-Z
                || (v >= 0x61 && v <= 0x7A)  // a-z
                || scalar == "_" || scalar == "-" || scalar == "." || scalar == "/" || scalar == "+" || scalar == "="
                || scalar == "@" || scalar == "%"
        }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func joinCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(quote).joined(separator: " ")
    }
}

// MARK: - Escalation

public struct EscalationPolicy: Sendable, Hashable {
    public var grace: Duration
    public init(grace: Duration = .milliseconds(400)) {
        self.grace = grace
    }
    public static func termThenKill(grace: Duration = .milliseconds(400)) -> EscalationPolicy {
        EscalationPolicy(grace: grace)
    }
}

// MARK: - Shared launch engine

enum ProcessLaunchEngine {
    static func requireCapabilities(
        _ request: ProcessLaunchRequest,
        profile: PlatformCapabilityProfile
    ) throws {
        switch request.mode {
        case .shell:
            // CORE-N04: shell is an explicit high-trust capability, not generic localProcess.
            // Throw the dedicated ProcessServiceError so callers can distinguish shell denial
            // from other capability failures without string-matching reasons.
            switch profile.availability(for: .localShellExecution) {
            case .local:
                break
            case .remote, .hostProvided, .dataOnly, .unavailable:
                throw ProcessServiceError.shellCapabilityRequired
            }
        case .direct:
            try profile.requireLocal(request.capabilityKind)
        }
    }

#if os(macOS)
    static func launch(
        _ request: ProcessLaunchRequest,
        profile: PlatformCapabilityProfile
    ) throws -> ProcessHandle {
        try requireCapabilities(request, profile: profile)

        if let cwd = request.currentDirectory {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir), isDir.boolValue else {
                throw ProcessServiceError.invalidWorkingDirectory(cwd.path)
            }
        }

        let process = Process()
        switch request.mode {
        case .direct:
            process.executableURL = URL(fileURLWithPath: request.executable)
            process.arguments = request.arguments
        case .shell:
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let cmd = ShellQuoting.joinCommand(executable: request.executable, arguments: request.arguments)
            process.arguments = ["-c", cmd]
        }

        if let cwd = request.currentDirectory {
            process.currentDirectoryURL = cwd
        }

        if request.mergeEnvironment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in request.environment { env[k] = v }
            process.environment = env
        } else if !request.environment.isEmpty {
            process.environment = request.environment
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        let handle = ProcessHandle(
            process: process,
            stdout: stdout,
            stderr: stderr,
            maxStdout: request.maxStdoutBytes,
            maxStderr: request.maxStderrBytes,
            eventBufferCapacity: request.eventBufferCapacity,
            timeout: request.timeout
        )
        do {
            try process.run()
        } catch {
            throw ProcessServiceError.launchFailed(String(describing: error))
        }
        handle.noteLaunched()
        return handle
    }
#else
    static func launch(
        _ request: ProcessLaunchRequest,
        profile: PlatformCapabilityProfile
    ) throws -> ProcessHandle {
        try requireCapabilities(request, profile: profile)
        throw ProcessServiceError.unavailableOnPlatform
    }
#endif
}

// MARK: - ProcessHandle

#if os(macOS)
/// Live handle for a launched process with multi-subscriber bounded output (CORE-N02/N03).
public final class ProcessHandle: @unchecked Sendable {
    public let id: UUID
    public private(set) var processIdentifier: Int32
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let lock = NSLock()
    private var _terminated = false
    private var _exit: ProcessExit?
    private var terminationWaiters: [CheckedContinuation<ProcessExit, Never>] = []
    private let eventHub = AsyncBroadcastHub<ProcessOutputEvent>(maxHistory: 128)
    private let eventPolicy: AsyncBroadcastHub<ProcessOutputEvent>.OverflowPolicy
    /// Serializes all hub publishes so stdout/stderr cannot race past `.exited`/finish.
    private let publishQueue = ProcessEventPublishQueue()
    private var timeoutTask: Task<Void, Never>?
    private var escalationTask: Task<Void, Never>?
    private let stdoutSpool: BoundedByteSpool
    private let stderrSpool: BoundedByteSpool
    private var stdoutDropped = 0
    private var stderrDropped = 0
    private var stdoutCapped = false
    private var stderrCapped = false
    private let maxStdout: Int
    private let maxStderr: Int

    fileprivate init(
        id: UUID = UUID(),
        process: Process,
        stdout: Pipe,
        stderr: Pipe,
        maxStdout: Int,
        maxStderr: Int,
        eventBufferCapacity: Int,
        timeout: Duration?
    ) {
        self.id = id
        self.process = process
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.processIdentifier = process.processIdentifier
        self.maxStdout = maxStdout
        self.maxStderr = maxStderr
        self.eventPolicy = .dropOldest(capacity: eventBufferCapacity, emitGap: true)
        self.stdoutSpool = BoundedByteSpool(maxBytes: maxStdout, overflow: .rejectNewest)
        self.stderrSpool = BoundedByteSpool(maxBytes: maxStderr, overflow: .rejectNewest)

        let outHandle = stdout.fileHandleForReading
        let errHandle = stderr.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            self?.emitStdout(data)
        }
        errHandle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            self?.emitStderr(data)
        }

        process.terminationHandler = { [weak self] proc in
            self?.drainAndFinish(code: proc.terminationStatus, timedOut: false)
        }

        if let timeout {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled else { return }
                if !self.isTerminated {
                    self.requestCancellation(escalation: .termThenKill())
                    self.drainAndFinish(code: 124, timedOut: true)
                }
            }
        }
    }

    fileprivate func noteLaunched() {
        processIdentifier = process.processIdentifier
        let pid = processIdentifier
        // Establish process group as early as possible after spawn (CORE-N03).
        if pid > 0 {
            _ = setpgid(pid, pid)
        }
        if !process.isRunning {
            let code = process.terminationStatus
            drainAndFinish(code: code, timedOut: false)
        }
    }

    public var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _terminated
    }

    /// Independent multi-consumer event subscription (CORE-N02).
    /// Each access creates a new bounded subscription — never share a single iterator.
    public var events: AsyncStream<ProcessOutputEvent> {
        // Bridge hub StreamItem → ProcessOutputEvent for API compatibility.
        let hub = eventHub
        let policy = eventPolicy
        return AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task {
                let stream = await hub.subscribe(policy: policy, replay: .allBuffered)
                for await item in stream {
                    switch item {
                    case .value(let env):
                        continuation.yield(env.event)
                    case .gap:
                        continuation.yield(.outputGap(stream: .stdout, droppedBytes: 0))
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

    /// Explicit subscription factory (preferred over ``events`` when policies matter).
    public func makeEventStream(
        capacity: Int = 64
    ) -> AsyncStream<ProcessOutputEvent> {
        let hub = eventHub
        let policy = AsyncBroadcastHub<ProcessOutputEvent>.OverflowPolicy.dropOldest(
            capacity: capacity,
            emitGap: true
        )
        return AsyncStream(bufferingPolicy: .bufferingOldest(max(1, capacity))) { continuation in
            let task = Task {
                let stream = await hub.subscribe(policy: policy, replay: .allBuffered)
                for await item in stream {
                    switch item {
                    case .value(let env):
                        continuation.yield(env.event)
                    case .gap:
                        continuation.yield(.outputGap(stream: .stdout, droppedBytes: 0))
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

    public func waitUntilExit() async -> (code: Int32, timedOut: Bool) {
        let exit = await awaitTermination()
        return (exit.code, exit.timedOut)
    }

    /// Wait until the process is reaped (CORE-N03). Separate from ``cancel()``.
    public func awaitTermination() async -> ProcessExit {
        if let exit = takeExitIfFinished() {
            return exit
        }
        return await withCheckedContinuation { cont in
            enqueueTerminationWaiter(cont)
        }
    }

    nonisolated private func takeExitIfFinished() -> ProcessExit? {
        lock.lock()
        defer { lock.unlock() }
        return _exit
    }

    nonisolated private func enqueueTerminationWaiter(_ cont: CheckedContinuation<ProcessExit, Never>) {
        lock.lock()
        if let exit = _exit {
            lock.unlock()
            cont.resume(returning: exit)
            return
        }
        terminationWaiters.append(cont)
        lock.unlock()
    }

    /// Request cancellation and return immediately (CORE-N03).
    /// Does **not** wait for process death — call ``awaitTermination()`` for that.
    public func cancel() {
        requestCancellation(escalation: .termThenKill())
    }

    public func requestCancellation(escalation: EscalationPolicy) {
        if isTerminated { return }
        terminateProcessGroup(escalation: escalation)
    }

    /// TERM process group, then KILL after grace on a background task (never blocks caller).
    public func terminateProcessGroup(escalation: EscalationPolicy = .termThenKill()) {
        let pid = process.processIdentifier
        guard pid > 0 else {
            if process.isRunning { process.terminate() }
            return
        }
        kill(-pid, SIGTERM)
        let grace = escalation.grace
        escalationTask?.cancel()
        escalationTask = Task { [process] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            if process.isRunning {
                kill(-pid, SIGKILL)
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Compatibility alias.
    public func terminateProcessGroup() {
        terminateProcessGroup(escalation: .termThenKill())
    }

    private func emitStdout(_ data: Data) {
        if isTerminated { return }
        let hub = eventHub
        let spool = stdoutSpool
        publishQueue.enqueue { [weak self] in
            guard let self else { return }
            let result = await spool.append(data)
            if result.truncated {
                let dropped = result.droppedBytes
                let shouldGap = self.noteStdoutDrop(dropped)
                if shouldGap {
                    await hub.publish(.outputGap(stream: .stdout, droppedBytes: dropped))
                }
                if result.acceptedBytes == 0 { return }
                await hub.publish(.stdout(Data(data.prefix(result.acceptedBytes))))
            } else {
                await hub.publish(.stdout(data))
            }
        }
    }

    private func emitStderr(_ data: Data) {
        if isTerminated { return }
        let hub = eventHub
        let spool = stderrSpool
        publishQueue.enqueue { [weak self] in
            guard let self else { return }
            let result = await spool.append(data)
            if result.truncated {
                let dropped = result.droppedBytes
                let shouldGap = self.noteStderrDrop(dropped)
                if shouldGap {
                    await hub.publish(.outputGap(stream: .stderr, droppedBytes: dropped))
                }
                if result.acceptedBytes == 0 { return }
                await hub.publish(.stderr(Data(data.prefix(result.acceptedBytes))))
            } else {
                await hub.publish(.stderr(data))
            }
        }
    }

    nonisolated private func noteStdoutDrop(_ dropped: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stdoutDropped += dropped
        if !stdoutCapped {
            stdoutCapped = true
            return true
        }
        return false
    }

    nonisolated private func noteStderrDrop(_ dropped: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stderrDropped += dropped
        if !stderrCapped {
            stderrCapped = true
            return true
        }
        return false
    }

    private func drainAndFinish(code: Int32, timedOut: Bool) {
        lock.lock()
        if _terminated {
            lock.unlock()
            return
        }
        _terminated = true
        let exit = ProcessExit(code: code, timedOut: timedOut)
        _exit = exit
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        lock.unlock()

        timeoutTask?.cancel()
        escalationTask?.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain remaining buffered pipe data, then publish exit/finish on the same serial queue
        // so no stdout/stderr Task can overtake termination.
        let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let hub = eventHub
        let outSpool = stdoutSpool
        let errSpool = stderrSpool
        publishQueue.enqueue {
            if !out.isEmpty {
                let result = await outSpool.append(out)
                if result.acceptedBytes > 0 {
                    await hub.publish(.stdout(Data(out.prefix(result.acceptedBytes))))
                }
            }
            if !err.isEmpty {
                let result = await errSpool.append(err)
                if result.acceptedBytes > 0 {
                    await hub.publish(.stderr(Data(err.prefix(result.acceptedBytes))))
                }
            }
            await hub.publish(.exited(code: code, timedOut: timedOut))
            await hub.finish(.completed)
        }

        for w in waiters {
            w.resume(returning: exit)
        }
    }

    deinit {
        if process.isRunning {
            terminateProcessGroup()
        }
    }
}
#else
/// Fail-closed handle type surface on platforms without Foundation.Process (e.g. iOS).
///
/// Production code never obtains a live handle: ``ProcessLaunchEngine/launch`` always throws
/// ``ProcessServiceError/unavailableOnPlatform`` after capability checks. Methods below are
/// therefore already-terminated / no-child semantics (cancel is a no-op because there is nothing
/// to wait on; ``awaitTermination`` returns immediately).
public final class ProcessHandle: @unchecked Sendable {
    public let id: UUID
    public private(set) var processIdentifier: Int32 = -1

    /// Unreachable from production launch paths; retained only so the public type exists on all platforms.
    fileprivate init(id: UUID = UUID()) {
        self.id = id
    }

    public var isTerminated: Bool { true }

    public var events: AsyncStream<ProcessOutputEvent> {
        AsyncStream { continuation in
            continuation.yield(.exited(code: -1, timedOut: false))
            continuation.finish()
        }
    }

    public func makeEventStream(capacity: Int = 64) -> AsyncStream<ProcessOutputEvent> {
        _ = capacity
        return events
    }

    public func waitUntilExit() async -> (code: Int32, timedOut: Bool) {
        (-1, false)
    }

    public func awaitTermination() async -> ProcessExit {
        ProcessExit(code: -1, timedOut: false)
    }

    /// Nonblocking: no child process exists on this platform.
    public func cancel() {}

    /// Nonblocking: no child process exists on this platform.
    public func requestCancellation(escalation: EscalationPolicy) { _ = escalation }

    /// Nonblocking: no process group exists on this platform.
    public func terminateProcessGroup(escalation: EscalationPolicy = .termThenKill()) { _ = escalation }

    public func terminateProcessGroup() {}
}
#endif

// MARK: - Serial publish queue

/// FIFO executor so process I/O events cannot race past exit/finish on the hub.
final class ProcessEventPublishQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            _ = await previous?.value
            await work()
        }
        tail = task
        lock.unlock()
    }
}

// MARK: - ProcessService (sync facade)

/// Launches local processes with streaming I/O and process-group lifecycle.
/// Shared non-PTY process launcher used by tasks, Git, and helpers.
///
/// Prefer ``ProcessSupervisor`` for supervised lifecycle (cancel/awaitExit).
public struct ProcessService: Sendable {
    public var profile: PlatformCapabilityProfile

    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }

    public func launch(_ request: ProcessLaunchRequest) throws -> ProcessHandle {
        try ProcessLaunchEngine.launch(request, profile: profile)
    }

    /// Convenience: run to completion collecting UTF-8 output.
    public func runCollecting(
        _ request: ProcessLaunchRequest
    ) async throws -> (stdout: String, stderr: String, code: Int32) {
        let handle = try launch(request)
        var out = Data()
        var err = Data()
        var code: Int32 = -1
        var timedOut = false
        for await event in handle.events {
            switch event {
            case .stdout(let d): out.append(d)
            case .stderr(let d): err.append(d)
            case .outputGap:
                break
            case .exited(let c, let t):
                code = c
                timedOut = t
            }
        }
        if timedOut { throw ProcessServiceError.timedOut }
        if Task.isCancelled {
            handle.cancel()
            _ = await handle.awaitTermination()
            throw ProcessServiceError.cancelled
        }
        let stdout = String(data: out, encoding: .utf8) ?? String(decoding: out, as: UTF8.self)
        let stderr = String(data: err, encoding: .utf8) ?? String(decoding: err, as: UTF8.self)
        return (stdout, stderr, code)
    }
}
