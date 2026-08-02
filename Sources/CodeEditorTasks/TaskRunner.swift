import CodeEditorCore
import Foundation

public protocol TaskRunner: Sendable {
    /// Start a task and return a live execution handle.
    func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle

    /// Convenience: run to completion.
    func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult
}

extension TaskRunner {
    public func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult {
        let handle = try await start(definition, output: output)
        return try await handle.wait()
    }
}

/// Live cancellable execution with streaming events.
public final class TaskExecutionHandle: @unchecked Sendable {
    public let runID: UUID
    public private(set) var run: TaskRun
    private let lock = NSLock()
    private var processHandle: ProcessHandle?
    private var continuation: AsyncStream<TaskOutputEvent>.Continuation?
    public let events: AsyncStream<TaskOutputEvent>
    private var stdout = ""
    private var stderr = ""
    private var finished = false
    private var waiters: [CheckedContinuation<TaskRunResult, Error>] = []
    private var readiness: NSRegularExpression?
    private var becameReady = false
    /// Rolling UTF-8 decode window so readiness regex can match across chunk boundaries (TASK-002).
    private var readinessWindow = ""
    private let readinessWindowMaxChars = 16_384
    private var utf8Carry = Data()

    public init(
        run: TaskRun,
        processHandle: ProcessHandle?,
        readinessPattern: String?
    ) {
        self.runID = run.id
        self.run = run
        self.processHandle = processHandle
        if let readinessPattern {
            self.readiness = try? NSRegularExpression(pattern: readinessPattern, options: [])
        }
        var cont: AsyncStream<TaskOutputEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        if let processHandle {
            Task { [weak self] in
                await self?.pump(processHandle)
            }
        }
    }

    /// Whether readiness was observed (background deps).
    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return becameReady
    }

    /// Host/fake runner completion without a process.
    public static func completed(
        run: TaskRun,
        stdout: String,
        stderr: String
    ) -> TaskExecutionHandle {
        var r = run
        if r.state == .queued || r.state == .starting || r.state == .running {
            r.state = (r.exitCode ?? 0) == 0 ? .succeeded : .failed
        }
        if r.endedAt == nil { r.endedAt = Date() }
        let handle = TaskExecutionHandle(run: r, processHandle: nil, readinessPattern: nil)
        handle.complete(run: r, stdout: stdout, stderr: stderr)
        return handle
    }

    /// Cancel the task. For process-backed runs, signals the process nonblocking
    /// (CORE-N03). Completion is observed by `pump` when the process dies
    /// (TASK-003 / §18.4 — exclusive slots stay held until death).
    public func cancel() {
        lock.lock()
        let hasProcess = processHandle != nil && !finished
        if !finished {
            var r = run
            r.state = .cancelled
            // endedAt set when process actually exits (or immediately if no process).
            if processHandle == nil {
                r.endedAt = Date()
            }
            run = r
        }
        lock.unlock()

        if hasProcess {
            // Nonblocking signal; pump + awaitTermination paths observe death.
            processHandle?.cancel()
            return
        }

        let snapshot = markCancelledIfNeeded()
        guard let snapshot else { return }
        complete(run: snapshot.run, stdout: snapshot.stdout, stderr: snapshot.stderr)
    }

    nonisolated private func markCancelledIfNeeded() -> (run: TaskRun, stdout: String, stderr: String)? {
        lock.lock()
        if finished {
            lock.unlock()
            return nil
        }
        var r = run
        r.state = .cancelled
        if r.endedAt == nil { r.endedAt = Date() }
        run = r
        let out = stdout
        let err = stderr
        lock.unlock()
        return (r, out, err)
    }

    public func wait() async throws -> TaskRunResult {
        if let immediate = takeIfFinished() {
            if immediate.run.state == .cancelled { throw TaskError.cancelled }
            if immediate.run.state == .timedOut { throw TaskError.timedOut }
            return immediate
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TaskRunResult, Error>) in
            enqueueWaiter(cont)
        }
    }

    nonisolated private func takeIfFinished() -> TaskRunResult? {
        lock.lock()
        defer { lock.unlock() }
        guard finished else { return nil }
        return TaskRunResult(run: run, stdout: stdout, stderr: stderr)
    }

    nonisolated private func enqueueWaiter(_ cont: CheckedContinuation<TaskRunResult, Error>) {
        lock.lock()
        if finished {
            let result = TaskRunResult(run: run, stdout: stdout, stderr: stderr)
            let state = run.state
            lock.unlock()
            if state == .cancelled {
                cont.resume(throwing: TaskError.cancelled)
            } else if state == .timedOut {
                cont.resume(throwing: TaskError.timedOut)
            } else {
                cont.resume(returning: result)
            }
            return
        }
        waiters.append(cont)
        lock.unlock()
    }

    public var collectedStdout: String {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    public var collectedStderr: String {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }

    /// Emit stdout/stderr into the handle (for fake/host runners).
    public func emit(stdout text: String) {
        let cont = appendStdout(text)
        cont?.yield(.stdout(text))
        markReadyIfNeeded(text)
    }

    public func emit(stderr text: String) {
        let cont = appendStderr(text)
        cont?.yield(.stderr(text))
        markReadyIfNeeded(text)
    }

    nonisolated private func appendStdout(_ text: String) -> AsyncStream<TaskOutputEvent>.Continuation? {
        lock.lock()
        stdout += text
        let cont = continuation
        lock.unlock()
        return cont
    }

    nonisolated private func appendStderr(_ text: String) -> AsyncStream<TaskOutputEvent>.Continuation? {
        lock.lock()
        stderr += text
        let cont = continuation
        lock.unlock()
        return cont
    }

    public func complete(run: TaskRun, stdout: String, stderr: String) {
        let sealed = sealCompletion(run: run, stdout: stdout, stderr: stderr)
        guard let sealed else { return }
        sealed.cont?.yield(.completed(run))
        sealed.cont?.finish()
        let result = TaskRunResult(run: run, stdout: stdout, stderr: stderr)
        for w in sealed.waiters {
            if run.state == .cancelled {
                w.resume(throwing: TaskError.cancelled)
            } else if run.state == .timedOut {
                w.resume(throwing: TaskError.timedOut)
            } else {
                w.resume(returning: result)
            }
        }
    }

    nonisolated private func sealCompletion(
        run: TaskRun,
        stdout: String,
        stderr: String
    ) -> (waiters: [CheckedContinuation<TaskRunResult, Error>], cont: AsyncStream<TaskOutputEvent>.Continuation?)? {
        lock.lock()
        if finished {
            lock.unlock()
            return nil
        }
        finished = true
        self.run = run
        self.stdout = stdout
        self.stderr = stderr
        let waiters = self.waiters
        self.waiters.removeAll()
        let cont = continuation
        continuation = nil
        lock.unlock()
        return (waiters, cont)
    }

    private func pump(_ handle: ProcessHandle) async {
        for await event in handle.events {
            switch event {
            case .stdout(let data):
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                emit(stdout: text)
            case .stderr(let data):
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                emit(stderr: text)
            case .outputGap:
                break
            case .exited(let code, let timedOut):
                let snapshot = applyExit(code: code, timedOut: timedOut)
                complete(run: snapshot.run, stdout: snapshot.stdout, stderr: snapshot.stderr)
            }
        }
    }

    /// NSLock is not usable from async contexts; keep mutation in a nonisolated helper.
    nonisolated private func applyExit(code: Int32, timedOut: Bool) -> (run: TaskRun, stdout: String, stderr: String) {
        lock.lock()
        var r = run
        r.exitCode = Int(code)
        r.endedAt = Date()
        if timedOut {
            r.state = .timedOut
        } else if r.state != .cancelled {
            r.state = code == 0 ? .succeeded : .failed
        }
        run = r
        let out = stdout
        let err = stderr
        lock.unlock()
        return (r, out, err)
    }

    nonisolated private func markReadyIfNeeded(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !becameReady, let readiness else { return }
        // Append to rolling window (may include previous incomplete chunk tail).
        readinessWindow += text
        if readinessWindow.count > readinessWindowMaxChars {
            readinessWindow = String(readinessWindow.suffix(readinessWindowMaxChars))
        }
        let range = NSRange(readinessWindow.startIndex..<readinessWindow.endIndex, in: readinessWindow)
        if readiness.firstMatch(in: readinessWindow, options: [], range: range) != nil {
            becameReady = true
            continuation?.yield(.ready)
        }
    }

    /// Feed raw process bytes through a streaming UTF-8 decoder before readiness matching.
    nonisolated func emitDecodedStdout(_ data: Data) {
        lock.lock()
        utf8Carry.append(data)
        // Decode complete prefix
        var end = utf8Carry.count
        while end > 0 {
            if let s = String(data: utf8Carry.prefix(end), encoding: .utf8) {
                let remainder = Data(utf8Carry.suffix(from: end))
                utf8Carry = remainder
                lock.unlock()
                emit(stdout: s)
                return
            }
            end -= 1
        }
        lock.unlock()
    }
}

// MARK: - Process runner

public struct ProcessTaskRunner: TaskRunner {
    public let platformProfile: PlatformCapabilityProfile
    /// Shared process launcher (PROC-001 / CORE substrate) — same API used by Git / helpers.
    public let processService: ProcessService
    public var defaultTimeout: Duration?

    public init(
        platformProfile: PlatformCapabilityProfile = .default(),
        defaultTimeout: Duration? = nil
    ) {
        self.platformProfile = platformProfile
        self.processService = ProcessService(profile: platformProfile)
        self.defaultTimeout = defaultTimeout
    }

    public func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle {
        try Task.checkCancellation()
        let resolved = try TaskVariableResolver.resolveDefinition(definition)
        var run = TaskRun(definitionID: resolved.id, state: .starting, startedAt: Date())
        if resolved.presentation.echo {
            output.append(text: "> \(resolved.executable) \(resolved.arguments.joined(separator: " "))")
        }

        let mode: ProcessLaunchMode = resolved.execution == .shell ? .shell : .direct
        let request = ProcessLaunchRequest(
            executable: resolved.executable,
            arguments: resolved.arguments,
            mode: mode,
            currentDirectory: resolved.cwd,
            environment: resolved.environment,
            mergeEnvironment: true,
            timeout: resolved.timeout ?? defaultTimeout,
            // Shell mode is gated by localShellExecution inside ProcessLaunchEngine (CORE-N04).
            capabilityKind: mode == .shell ? .localShellExecution : .localProcess
        )

        let processHandle: ProcessHandle
        do {
            processHandle = try processService.launch(request)
        } catch let error as CodeEditorPlatformError {
            throw error
        } catch let error as ProcessServiceError {
            run.state = .failed
            run.endedAt = Date()
            throw TaskError.processFailed(String(describing: error))
        } catch {
            run.state = .failed
            run.endedAt = Date()
            throw TaskError.processFailed(String(describing: error))
        }

        run.state = .running
        let handle = TaskExecutionHandle(
            run: run,
            processHandle: processHandle,
            readinessPattern: resolved.readinessPattern
        )

        Task {
            for await event in handle.events {
                switch event {
                case .stdout(let t): output.append(text: t, isError: false)
                case .stderr(let t): output.append(text: t, isError: true)
                case .ready, .completed: break
                }
            }
        }
        return handle
    }
}

// MARK: - Host / remote runners

/// Host-supplied runner for iOS/sandbox profiles (no local process).
public protocol HostTaskExecuting: Sendable {
    func execute(_ definition: TaskDefinition) async throws -> TaskRunResult
}

public struct HostTaskRunner: TaskRunner {
    public let executor: any HostTaskExecuting

    public init(executor: any HostTaskExecuting) {
        self.executor = executor
    }

    public func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle {
        let resolved = try TaskVariableResolver.resolveDefinition(definition)
        let result = try await executor.execute(resolved)
        output.append(text: result.stdout, isError: false)
        output.append(text: result.stderr, isError: true)
        return TaskExecutionHandle.completed(
            run: result.run,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}
