import Foundation
import CodeEditorCore

public protocol TaskRunner: Sendable {
    /// Start a task and return a live execution handle.
    func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle

    /// Convenience: run to completion.
    func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult
}

public extension TaskRunner {
    func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult {
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

    public func cancel() {
        processHandle?.cancel()
        let snapshot = markCancelled()
        guard let snapshot else { return }
        complete(run: snapshot.run, stdout: snapshot.stdout, stderr: snapshot.stderr)
    }

    nonisolated private func markCancelled() -> (run: TaskRun, stdout: String, stderr: String)? {
        lock.lock()
        if finished {
            lock.unlock()
            return nil
        }
        var r = run
        r.state = .cancelled
        r.endedAt = Date()
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
        lock.lock(); defer { lock.unlock() }
        return stdout
    }

    public var collectedStderr: String {
        lock.lock(); defer { lock.unlock() }
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
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if readiness.firstMatch(in: text, options: [], range: range) != nil {
            becameReady = true
            continuation?.yield(.ready)
        }
    }
}

// MARK: - Process runner

public struct ProcessTaskRunner: TaskRunner {
    public let platformProfile: PlatformCapabilityProfile
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
        let resolved = TaskVariableResolver.resolveDefinition(definition)
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
            capabilityKind: .localProcess
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
        let resolved = TaskVariableResolver.resolveDefinition(definition)
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

/// In-process fake for tests (streaming + cancel + readiness).
public struct FakeTaskRunner: TaskRunner, Sendable {
    public var stdoutChunks: [String]
    public var stderrChunks: [String]
    public var exitCode: Int32
    public var chunkDelayNanoseconds: UInt64
    public var hangUntilCancelled: Bool

    public init(
        stdoutChunks: [String] = ["ok\n"],
        stderrChunks: [String] = [],
        exitCode: Int32 = 0,
        chunkDelayNanoseconds: UInt64 = 0,
        hangUntilCancelled: Bool = false
    ) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
        self.exitCode = exitCode
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
        self.hangUntilCancelled = hangUntilCancelled
    }

    public func start(
        _ definition: TaskDefinition,
        output: OutputChannel
    ) async throws -> TaskExecutionHandle {
        let run = TaskRun(definitionID: definition.id, state: .running, startedAt: Date())
        let handle = TaskExecutionHandle(
            run: run,
            processHandle: nil,
            readinessPattern: definition.readinessPattern
        )
        let chunks = stdoutChunks
        let errChunks = stderrChunks
        let delay = chunkDelayNanoseconds
        let hang = hangUntilCancelled
        let code = exitCode
        Task {
            if hang {
                while true {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    if handle.run.state == .cancelled { return }
                }
            }
            var out = ""
            var err = ""
            for chunk in chunks {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                if handle.run.state == .cancelled { return }
                handle.emit(stdout: chunk)
                output.append(text: chunk, isError: false)
                out += chunk
            }
            for chunk in errChunks {
                handle.emit(stderr: chunk)
                output.append(text: chunk, isError: true)
                err += chunk
            }
            var done = handle.run
            done.state = code == 0 ? .succeeded : .failed
            done.exitCode = Int(code)
            done.endedAt = Date()
            handle.complete(run: done, stdout: out, stderr: err)
        }
        return handle
    }
}
