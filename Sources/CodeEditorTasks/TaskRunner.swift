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

/// Live cancellable execution with multicast streaming events (TASK-N01…N08).
///
/// Events are published through ``AsyncBroadcastHub`` so every consumer receives
/// an independent bounded subscription. Output is spool-bounded with a single
/// truncation marker per stream. UTF-8 is decoded with per-stream incremental
/// decoders so multibyte scalars split across reads stay intact.
public final class TaskExecutionHandle: @unchecked Sendable {
    public let runID: UUID
    public private(set) var run: TaskRun
    public let maxCollectedBytes: Int

    private let lock = NSLock()
    private var processHandle: ProcessHandle?
    private let eventHub = AsyncBroadcastHub<TaskOutputEvent>(maxHistory: 256)
    private let eventPolicy: AsyncBroadcastHub<TaskOutputEvent>.OverflowPolicy
    private let publishQueue = TaskEventPublishQueue()

    private var stdoutDecoder = IncrementalUTF8Decoder()
    private var stderrDecoder = IncrementalUTF8Decoder()
    private let stdoutSpool: BoundedByteSpool
    private let stderrSpool: BoundedByteSpool
    private var stdoutTruncationEmitted = false
    private var stderrTruncationEmitted = false
    private var droppedStdoutBytes = 0
    private var droppedStderrBytes = 0

    private var finished = false
    private var waiters: [CheckedContinuation<TaskRunResult, Error>] = []
    private var readiness: NSRegularExpression?
    private var becameReady = false
    /// Rolling UTF-8 decode window so readiness regex can match across chunk boundaries.
    private var readinessWindow = ""
    private let readinessWindowMaxChars = 16_384
    /// Cached decoded text for wait()/collected (bounded by spool).
    private var stdoutTextCache = ""
    private var stderrTextCache = ""

    public init(
        run: TaskRun,
        processHandle: ProcessHandle?,
        readinessPattern: String?,
        maxCollectedBytes: Int = 1_048_576
    ) throws {
        self.runID = run.id
        self.run = run
        self.processHandle = processHandle
        self.maxCollectedBytes = max(1, maxCollectedBytes)
        self.eventPolicy = .dropOldest(capacity: 256, emitGap: true)
        self.stdoutSpool = BoundedByteSpool(maxBytes: self.maxCollectedBytes, overflow: .dropOldest)
        self.stderrSpool = BoundedByteSpool(maxBytes: self.maxCollectedBytes, overflow: .dropOldest)
        self.readiness = try TaskError.validateReadinessPattern(readinessPattern)

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

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    public var wasOutputTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdoutTruncationEmitted || stderrTruncationEmitted
    }

    public var droppedOutputByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedStdoutBytes + droppedStderrBytes
    }

    /// Independent multi-consumer event subscription (TASK-N01).
    /// Each access creates a new bounded subscription — never share a single iterator.
    public var events: AsyncStream<TaskOutputEvent> {
        makeEventStream()
    }

    /// Explicit subscription factory (preferred when capacity matters).
    public func makeEventStream(capacity: Int = 256) -> AsyncStream<TaskOutputEvent> {
        let hub = eventHub
        let policy = AsyncBroadcastHub<TaskOutputEvent>.OverflowPolicy.dropOldest(
            capacity: max(1, capacity),
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
                        // Task consumers care about text truncation (outputTruncated), not sequence gaps.
                        break
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
        // Force-try: nil readinessPattern always validates.
        let handle = try! TaskExecutionHandle(run: r, processHandle: nil, readinessPattern: nil)
        handle.finishSynchronously(run: r, stdout: stdout, stderr: stderr)
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
            if processHandle == nil {
                r.endedAt = Date()
            }
            run = r
        }
        lock.unlock()

        if hasProcess {
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
        let out = stdoutTextCache
        let err = stderrTextCache
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
        return TaskRunResult(run: run, stdout: stdoutTextCache, stderr: stderrTextCache)
    }

    nonisolated private func enqueueWaiter(_ cont: CheckedContinuation<TaskRunResult, Error>) {
        lock.lock()
        if finished {
            let result = TaskRunResult(run: run, stdout: stdoutTextCache, stderr: stderrTextCache)
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

    /// Bounded decoded stdout (TASK-N04) — never retains unbounded full process output.
    public var collectedStdout: String {
        lock.lock()
        defer { lock.unlock() }
        return stdoutTextCache
    }

    public var collectedStderr: String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTextCache
    }

    /// Raw spool bytes for binary/terminal consumers (TASK-N02).
    public func rawStdoutBytes() async -> Data {
        await stdoutSpool.readAll()
    }

    public func rawStderrBytes() async -> Data {
        await stderrSpool.readAll()
    }

    /// Sequence-range / UI viewport read over the bounded stdout spool (TASK-N03).
    public func rawStdoutViewport(from offset: UInt64, maxBytes: Int) async -> BoundedByteSpool.ViewportRead {
        await stdoutSpool.read(from: offset, maxBytes: maxBytes)
    }

    /// Sequence-range / UI viewport read over the bounded stderr spool (TASK-N03).
    public func rawStderrViewport(from offset: UInt64, maxBytes: Int) async -> BoundedByteSpool.ViewportRead {
        await stderrSpool.read(from: offset, maxBytes: maxBytes)
    }

    /// Emit decoded stdout text into the handle (for fake/host runners).
    /// Waits until the text is published so subsequent reads observe the update.
    public func emit(stdout text: String) {
        runOnPublishQueue {
            await self.publishText(text, stream: .stdout)
        }
    }

    public func emit(stderr text: String) {
        runOnPublishQueue {
            await self.publishText(text, stream: .stderr)
        }
    }

    /// Feed raw process bytes through the incremental UTF-8 decoder (TASK-N02).
    public func emitRawStdout(_ data: Data) async {
        await runOnPublishQueueAsync {
            await self.publishRaw(data, stream: .stdout)
        }
    }

    public func emitRawStderr(_ data: Data) async {
        await runOnPublishQueueAsync {
            await self.publishRaw(data, stream: .stderr)
        }
    }

    /// Finish the handle exactly once (TASK-N08). Ordered after any prior emit on the publish queue.
    public func complete(run: TaskRun, stdout: String, stderr: String) {
        runOnPublishQueue {
            await self.sealAndFinish(run: run, stdout: stdout, stderr: stderr)
        }
    }

    /// Immediate finish used by ``completed`` factory (no prior async emits to order against).
    fileprivate func finishSynchronously(run: TaskRun, stdout: String, stderr: String) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        self.run = run
        stdoutTextCache = Self.clamp(stdout, maxBytes: maxCollectedBytes)
        stderrTextCache = Self.clamp(stderr, maxBytes: maxCollectedBytes)
        let waiters = self.waiters
        self.waiters.removeAll()
        let outSnap = stdoutTextCache
        let errSnap = stderrTextCache
        lock.unlock()

        publishQueue.enqueue { [eventHub] in
            await eventHub.publish(.completed(run))
            await eventHub.finish(.completed)
        }

        let result = TaskRunResult(run: run, stdout: outSnap, stderr: errSnap)
        for w in waiters {
            if run.state == .cancelled {
                w.resume(throwing: TaskError.cancelled)
            } else if run.state == .timedOut {
                w.resume(throwing: TaskError.timedOut)
            } else {
                w.resume(returning: result)
            }
        }
    }

    private func runOnPublishQueue(_ work: @escaping @Sendable () async -> Void) {
        let gate = TaskCompletionGate()
        publishQueue.enqueue {
            await work()
            gate.open()
        }
        gate.wait()
    }

    private func runOnPublishQueueAsync(_ work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            publishQueue.enqueue {
                await work()
                cont.resume()
            }
        }
    }

    private func publishRaw(_ data: Data, stream: TaskOutputStream) async {
        if isFinishedSync() { return }

        let spool = stream == .stdout ? stdoutSpool : stderrSpool
        let result = await spool.append(data)
        let applied = applyDecodedChunk(data, stream: stream, spoolResult: result)

        if applied.shouldTruncate {
            await eventHub.publish(
                .outputTruncated(stream: stream, droppedBytes: applied.droppedBytes)
            )
        }
        if !applied.text.isEmpty {
            switch stream {
            case .stdout:
                await eventHub.publish(.stdout(applied.text))
                markReadyIfNeeded(applied.text)
            case .stderr:
                await eventHub.publish(.stderr(applied.text))
                markReadyIfNeeded(applied.text)
            }
        }
    }

    private func publishText(_ text: String, stream: TaskOutputStream) async {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        await publishRaw(data, stream: stream)
    }

    private func sealAndFinish(run: TaskRun, stdout: String, stderr: String) async {
        guard let sealed = sealCompletionSync(run: run, stdout: stdout, stderr: stderr) else {
            return
        }

        if !sealed.outTail.isEmpty {
            await eventHub.publish(.stdout(sealed.outTail))
        }
        if !sealed.errTail.isEmpty {
            await eventHub.publish(.stderr(sealed.errTail))
        }
        await eventHub.publish(.completed(run))
        await eventHub.finish(.completed)

        let result = TaskRunResult(run: run, stdout: sealed.stdout, stderr: sealed.stderr)
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

    private func pump(_ handle: ProcessHandle) async {
        for await event in handle.events {
            switch event {
            case .stdout(let data):
                await emitRawStdout(data)
            case .stderr(let data):
                await emitRawStderr(data)
            case .outputGap(let stream, let dropped):
                let shouldEmit = noteProcessOutputGap(stream: stream, dropped: dropped)
                if shouldEmit {
                    let taskStream: TaskOutputStream = stream == .stdout ? .stdout : .stderr
                    await eventHub.publish(.outputTruncated(stream: taskStream, droppedBytes: dropped))
                }
            case .exited(let code, let timedOut):
                let snapshot = applyExit(code: code, timedOut: timedOut)
                await sealAndFinish(run: snapshot.run, stdout: snapshot.stdout, stderr: snapshot.stderr)
            }
        }
        // If process stream ended without exit (should not happen), fail closed.
        if !isFinishedSync() {
            let snapshot = applyExit(code: -1, timedOut: false)
            await sealAndFinish(run: snapshot.run, stdout: snapshot.stdout, stderr: snapshot.stderr)
        }
    }

    nonisolated private func isFinishedSync() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    nonisolated private func applyDecodedChunk(
        _ data: Data,
        stream: TaskOutputStream,
        spoolResult: BoundedByteSpool.AppendResult
    ) -> (text: String, shouldTruncate: Bool, droppedBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        var decoder = stream == .stdout ? stdoutDecoder : stderrDecoder
        let decoded = decoder.push(data)
        if stream == .stdout {
            stdoutDecoder = decoder
        } else {
            stderrDecoder = decoder
        }
        let text = decoded.text
        if !text.isEmpty {
            if stream == .stdout {
                stdoutTextCache = Self.appendBounded(stdoutTextCache, text, maxBytes: maxCollectedBytes)
            } else {
                stderrTextCache = Self.appendBounded(stderrTextCache, text, maxBytes: maxCollectedBytes)
            }
        }
        var shouldTruncate = false
        var dropped = 0
        if spoolResult.truncated {
            dropped = spoolResult.droppedBytes
            if stream == .stdout {
                droppedStdoutBytes += dropped
                if !stdoutTruncationEmitted {
                    stdoutTruncationEmitted = true
                    shouldTruncate = true
                }
            } else {
                droppedStderrBytes += dropped
                if !stderrTruncationEmitted {
                    stderrTruncationEmitted = true
                    shouldTruncate = true
                }
            }
        }
        return (text, shouldTruncate, dropped)
    }

    nonisolated private func sealCompletionSync(
        run: TaskRun,
        stdout: String,
        stderr: String
    ) -> (
        waiters: [CheckedContinuation<TaskRunResult, Error>],
        stdout: String,
        stderr: String,
        outTail: String,
        errTail: String
    )? {
        lock.lock()
        if finished {
            lock.unlock()
            return nil
        }
        let outTail = stdoutDecoder.finish()
        let errTail = stderrDecoder.finish()
        if !outTail.isEmpty {
            stdoutTextCache = Self.appendBounded(stdoutTextCache, outTail, maxBytes: maxCollectedBytes)
        }
        if !errTail.isEmpty {
            stderrTextCache = Self.appendBounded(stderrTextCache, errTail, maxBytes: maxCollectedBytes)
        }
        if !stdout.isEmpty { stdoutTextCache = Self.clamp(stdout, maxBytes: maxCollectedBytes) }
        if !stderr.isEmpty { stderrTextCache = Self.clamp(stderr, maxBytes: maxCollectedBytes) }
        finished = true
        self.run = run
        let waiters = self.waiters
        self.waiters.removeAll()
        let outSnap = stdoutTextCache
        let errSnap = stderrTextCache
        lock.unlock()
        return (waiters, outSnap, errSnap, outTail, errTail)
    }

    nonisolated private func noteProcessOutputGap(
        stream: ProcessOutputStream,
        dropped: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stream == .stdout {
            droppedStdoutBytes += dropped
            if !stdoutTruncationEmitted {
                stdoutTruncationEmitted = true
                return true
            }
        } else {
            droppedStderrBytes += dropped
            if !stderrTruncationEmitted {
                stderrTruncationEmitted = true
                return true
            }
        }
        return false
    }

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
        let out = stdoutTextCache
        let err = stderrTextCache
        lock.unlock()
        return (r, out, err)
    }

    nonisolated private func markReadyIfNeeded(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !becameReady, let readiness else { return }
        readinessWindow += text
        if readinessWindow.count > readinessWindowMaxChars {
            readinessWindow = String(readinessWindow.suffix(readinessWindowMaxChars))
        }
        let range = NSRange(readinessWindow.startIndex..<readinessWindow.endIndex, in: readinessWindow)
        if readiness.firstMatch(in: readinessWindow, options: [], range: range) != nil {
            becameReady = true
            let hub = eventHub
            publishQueue.enqueue {
                await hub.publish(.ready)
            }
        }
    }

    private static func appendBounded(_ existing: String, _ addition: String, maxBytes: Int) -> String {
        clamp(existing + addition, maxBytes: maxBytes)
    }

    private static func clamp(_ text: String, maxBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        // Keep newest bytes (dropOldest semantics).
        let suffix = data.suffix(maxBytes)
        return String(decoding: suffix, as: UTF8.self)
    }
}

// MARK: - Serial publish queue

/// FIFO executor so task I/O events cannot race past completed/finish on the hub.
final class TaskEventPublishQueue: @unchecked Sendable {
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

/// Bridge so sync `emit`/`complete` wait for ordered async hub publishes.
final class TaskCompletionGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait() { semaphore.wait() }
}

// MARK: - Process runner

public struct ProcessTaskRunner: TaskRunner {
    public let platformProfile: PlatformCapabilityProfile
    /// Shared process launcher (PROC-001 / CORE substrate) — same API used by Git / helpers.
    public let processService: ProcessService
    public var defaultTimeout: Duration?
    public var maxCollectedBytes: Int

    public init(
        platformProfile: PlatformCapabilityProfile = .default(),
        defaultTimeout: Duration? = nil,
        maxCollectedBytes: Int = 1_048_576
    ) {
        self.platformProfile = platformProfile
        self.processService = ProcessService(profile: platformProfile)
        self.defaultTimeout = defaultTimeout
        self.maxCollectedBytes = maxCollectedBytes
    }

    public func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle {
        try Task.checkCancellation()
        let resolved = try TaskVariableResolver.resolveDefinition(definition)
        // TASK-N05: validate readiness before launch (source-located config error).
        _ = try TaskError.validateReadinessPattern(resolved.readinessPattern)

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
        let handle = try TaskExecutionHandle(
            run: run,
            processHandle: processHandle,
            readinessPattern: resolved.readinessPattern,
            maxCollectedBytes: maxCollectedBytes
        )

        Task {
            for await event in handle.events {
                switch event {
                case .stdout(let t): output.append(text: t, isError: false)
                case .stderr(let t): output.append(text: t, isError: true)
                case .outputTruncated(let stream, let dropped):
                    output.append(
                        text: "[output truncated; dropped \(dropped) bytes on \(stream.rawValue)]",
                        isError: true
                    )
                case .ready:
                    break
                case .completed:
                    output.finish(reason: .completed)
                }
            }
            if !output.isFinished {
                output.finish(reason: .completed)
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
        _ = try TaskError.validateReadinessPattern(resolved.readinessPattern)
        let result = try await executor.execute(resolved)
        output.append(text: result.stdout, isError: false)
        output.append(text: result.stderr, isError: true)
        let handle = TaskExecutionHandle.completed(
            run: result.run,
            stdout: result.stdout,
            stderr: result.stderr
        )
        output.finish(reason: .completed)
        return handle
    }
}
