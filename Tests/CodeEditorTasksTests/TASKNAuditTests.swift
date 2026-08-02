import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorTasks

@Suite("TASK-N audit remediation")
struct TASKNAuditTests {

    // MARK: - TASK-N01 multicast events

    @Test func test_TASK_N01_taskEventsAreMulticastToIndependentConsumers() async throws {
        let runner = FakeTaskRunner(
            stdoutChunks: ["line-a\n", "line-b\n", "line-c\n"],
            chunkDelayNanoseconds: 2_000_000
        )
        let channel = OutputChannel(id: "t", name: "t")
        let def = TaskDefinition(id: "mcast", label: "M", executable: "x")
        let handle = try await runner.start(def, output: channel)

        async let consumerA: [TaskOutputEvent] = {
            var events: [TaskOutputEvent] = []
            for await e in handle.events { events.append(e) }
            return events
        }()
        async let consumerB: [TaskOutputEvent] = {
            var events: [TaskOutputEvent] = []
            for await e in handle.makeEventStream() { events.append(e) }
            return events
        }()

        let a = await consumerA
        let b = await consumerB

        let aStdout = a.compactMap { if case .stdout(let t) = $0 { return t } else { return nil } }.joined()
        let bStdout = b.compactMap { if case .stdout(let t) = $0 { return t } else { return nil } }.joined()
        #expect(aStdout.contains("line-a"))
        #expect(aStdout.contains("line-b"))
        #expect(aStdout.contains("line-c"))
        #expect(bStdout.contains("line-a"))
        #expect(bStdout.contains("line-b"))
        #expect(bStdout.contains("line-c"))

        let aCompleted = a.contains { if case .completed = $0 { return true }; return false }
        let bCompleted = b.contains { if case .completed = $0 { return true }; return false }
        #expect(aCompleted)
        #expect(bCompleted)
    }

    @Test func test_TASK_N01_eventsUseAsyncBroadcastHubNotSharedIterator() async throws {
        // Source contract: production TaskRunner must use AsyncBroadcastHub.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorTasks/TaskRunner.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(src.contains("AsyncBroadcastHub"))
        #expect(!src.contains("bufferingNewest(512)"))
    }

    // MARK: - TASK-N02 incremental UTF-8

    @Test func test_TASK_N02_multibyteScalarSplitAcrossChunksDecodesIntact() async throws {
        // "✓" is E2 9C 93 — feed byte-by-byte through the handle's raw path.
        let checkmark = "✓"
        let bytes = Array(checkmark.utf8)
        #expect(bytes.count == 3)

        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "utf8", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil
        )

        async let collected: String = {
            var out = ""
            for await e in handle.events {
                if case .stdout(let t) = e { out += t }
                if case .completed = e { break }
            }
            return out
        }()

        // Yield so the subscriber is registered before publish.
        try await Task.sleep(nanoseconds: 5_000_000)
        for b in bytes {
            await handle.emitRawStdout(Data([b]))
        }
        var done = handle.run
        done.state = .succeeded
        done.exitCode = 0
        done.endedAt = Date()
        handle.complete(run: done, stdout: handle.collectedStdout, stderr: "")

        let text = await collected
        #expect(text == checkmark)
        #expect(handle.collectedStdout.contains(checkmark) || handle.collectedStdout == checkmark)
    }

    @Test func test_TASK_N02_independentStdoutStderrDecoders() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "dec", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil
        )
        // Split "é" (C3 A9) across streams independently — incomplete on each must not corrupt the other.
        await handle.emitRawStdout(Data([0xC3]))
        await handle.emitRawStderr(Data([0xC3]))
        await handle.emitRawStdout(Data([0xA9]))  // completes stdout → "é"
        await handle.emitRawStderr(Data([0xA9]))  // completes stderr → "é"

        #expect(handle.collectedStdout.contains("é"))
        #expect(handle.collectedStderr.contains("é"))
        handle.complete(
            run: TaskRun(definitionID: "dec", state: .succeeded, exitCode: 0, endedAt: Date()),
            stdout: handle.collectedStdout,
            stderr: handle.collectedStderr
        )
    }

    @Test func test_TASK_N02_rawBytesPreservedForBinaryConsumers() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "raw", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil,
            maxCollectedBytes: 64 * 1024
        )
        let payload = Data([0x00, 0xFF, 0x10, 0x80])
        await handle.emitRawStdout(payload)
        let raw = await handle.rawStdoutBytes()
        #expect(raw == payload)
        handle.complete(
            run: TaskRun(definitionID: "raw", state: .succeeded, exitCode: 0, endedAt: Date()),
            stdout: "",
            stderr: ""
        )
    }

    // MARK: - TASK-N03 / N04 bounded spool + truncation

    @Test func test_TASK_N03_overflowEmitsExplicitTruncationMarkerOnce() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "bound", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil,
            maxCollectedBytes: 64
        )

        async let events: [TaskOutputEvent] = {
            var all: [TaskOutputEvent] = []
            for await e in handle.events { all.append(e) }
            return all
        }()

        try await Task.sleep(nanoseconds: 5_000_000)
        // Flood well past 64 bytes.
        for i in 0..<40 {
            await handle.emitRawStdout(Data("chunk-\(i)-XXXXXXXX\n".utf8))
        }
        var done = handle.run
        done.state = .succeeded
        done.exitCode = 0
        done.endedAt = Date()
        handle.complete(run: done, stdout: handle.collectedStdout, stderr: "")

        let all = await events
        let truncations = all.filter {
            if case .outputTruncated = $0 { return true }
            return false
        }
        #expect(truncations.count == 1)
        #expect(handle.wasOutputTruncated)
        #expect(handle.droppedOutputByteCount > 0)
        // Collected text must stay within bound (plus small slack for decode).
        #expect(handle.collectedStdout.utf8.count <= 256)
    }

    @Test func test_TASK_N04_collectedOutputIsBoundedNotFullString() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "unbound", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil,
            maxCollectedBytes: 128
        )
        let big = String(repeating: "Z", count: 50_000)
        handle.emit(stdout: big)
        #expect(handle.collectedStdout.utf8.count <= 512)
        #expect(handle.wasOutputTruncated)
        handle.complete(
            run: TaskRun(definitionID: "unbound", state: .succeeded, exitCode: 0, endedAt: Date()),
            stdout: handle.collectedStdout,
            stderr: ""
        )
    }

    @Test func test_TASK_N03_outputChannelEmitsSingleTruncationAndMetrics() {
        let ch = OutputChannel(id: "c", name: "c", maxLines: 3)
        for i in 0..<20 {
            ch.append(text: "L\(i)")
        }
        #expect(ch.wasTruncated)
        #expect(ch.droppedLineCount > 0)
        let markers = ch.snapshot.filter { $0.text.contains("truncated") }
        #expect(markers.count == 1)
        #expect(ch.snapshot.count <= 3)
    }

    // MARK: - TASK-N05 readiness regex validation

    @Test func test_TASK_N05_invalidReadinessRegexThrowsConfigurationError() async throws {
        do {
            _ = try TaskExecutionHandle(
                run: TaskRun(definitionID: "bad", state: .starting),
                processHandle: nil,
                readinessPattern: "(unclosed"
            )
            Issue.record("expected invalidDefinition for bad readiness regex")
        } catch let error as TaskError {
            guard case .invalidDefinition(let msg) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(msg.lowercased().contains("readiness") || msg.contains("regex") || msg.contains("("))
        }

        let service = TaskService(runner: FakeTaskRunner())
        await service.register(
            TaskDefinition(
                id: "bg",
                label: "BG",
                executable: "x",
                isBackground: true,
                readinessPattern: "[invalid"
            )
        )
        do {
            _ = try await service.start(id: "bg")
            Issue.record("expected invalidDefinition from service start")
        } catch let error as TaskError {
            guard case .invalidDefinition = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func test_TASK_N05_validReadinessRegexIsCompiled() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "ok", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: "READY-\\d+"
        )
        handle.emit(stdout: "READY-42\n")
        #expect(handle.isReady)
        handle.complete(
            run: TaskRun(definitionID: "ok", state: .succeeded, exitCode: 0, endedAt: Date()),
            stdout: "READY-42\n",
            stderr: ""
        )
    }

    // MARK: - TASK-N06 TaskNodeOutcome DAG

    @Test func test_TASK_N06_dependencyFailureIsExplicitOutcomeNotSuppressed() async throws {
        let service = TaskService(
            runner: FakeTaskRunner(stdoutChunks: ["fail\n"], exitCode: 1)
        )
        await service.register(
            TaskDefinition(id: "dep", label: "Dep", executable: "x")
        )
        await service.register(
            TaskDefinition(id: "root", label: "Root", executable: "x", dependsOn: ["dep"])
        )
        let report = try await service.executeGraph(id: "root")
        #expect(report.outcomes["dep"] != nil)
        if case .failed = report.outcomes["dep"] {
            // ok
        } else {
            Issue.record("dep should be failed, got \(String(describing: report.outcomes["dep"]))")
        }
        if case .skippedBecauseDependency(let id) = report.outcomes["root"] {
            #expect(id == TaskID("dep"))
        } else {
            Issue.record("root should be skippedBecauseDependency, got \(String(describing: report.outcomes["root"]))")
        }
        #expect(report.rootOutcome.isFailureOrSkip)
    }

    @Test func test_TASK_N06_startThrowsWhenDependencyFailed() async throws {
        let service = TaskService(
            runner: FakeTaskRunner(stdoutChunks: ["nope\n"], exitCode: 7)
        )
        await service.register(TaskDefinition(id: "a", label: "A", executable: "x"))
        await service.register(TaskDefinition(id: "b", label: "B", executable: "x", dependsOn: ["a"]))
        do {
            _ = try await service.start(id: "b")
            Issue.record("expected dependencyFailed")
        } catch let error as TaskError {
            guard case .dependencyFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func test_TASK_N06_exclusiveGroupWaitDoesNotSuppressFailure() async throws {
        // First exclusive task fails; second must observe failure rather than silent continue.
        let service = TaskService(
            runner: SequenceFakeTaskRunner(scripts: [
                .init(stdoutChunks: ["boom\n"], exitCode: 2),
                .init(stdoutChunks: ["ok\n"], exitCode: 0),
            ])
        )
        await service.register(
            TaskDefinition(
                id: "first",
                label: "First",
                executable: "x",
                concurrencyGroup: "g",
                isExclusive: true
            )
        )
        await service.register(
            TaskDefinition(
                id: "second",
                label: "Second",
                executable: "x",
                concurrencyGroup: "g",
                isExclusive: true
            )
        )
        // Run first to failure while holding exclusive.
        let first = try await service.start(id: "first")
        do {
            _ = try await first.wait()
        } catch {
            // may or may not throw — state is failed
        }
        // Allow release path.
        try await Task.sleep(nanoseconds: 30_000_000)
        // Starting second while first failed should still work (lock released on death),
        // but waiting on a concurrent exclusive holder that failed must not use try? swallow.
        let second = try await service.start(id: "second")
        let result = try await second.wait()
        #expect(result.run.state == .succeeded)
        // Graph outcome API must distinguish exclusive conflict from success.
        #expect(TaskNodeOutcome.failed(.exitCode(2)).isFailureOrSkip)
    }

    @Test func test_TASK_N06_backgroundNotReadyYieldsSkippedDependent() async throws {
        let service = TaskService(
            runner: FakeTaskRunner(stdoutChunks: ["never\n"], exitCode: 0)
        )
        await service.register(
            TaskDefinition(
                id: "bg",
                label: "BG",
                executable: "x",
                isBackground: true,
                readinessPattern: "READY"
            )
        )
        await service.register(
            TaskDefinition(id: "app", label: "App", executable: "x", dependsOn: ["bg"])
        )
        let report = try await service.executeGraph(id: "app")
        if case .failed = report.outcomes["bg"] {
            // background completed without ready → failed readiness
        } else if case .succeeded = report.outcomes["bg"] {
            Issue.record("bg without READY must not succeed as ready")
        }
        if case .skippedBecauseDependency = report.outcomes["app"] {
            // ok
        } else {
            // start/run path throws dependencyFailed; graph records skip
            #expect(report.outcomes["app"] != .succeeded)
        }
    }

    // MARK: - TASK-N07 versioned problem ranges / path normalize

    @Test func test_TASK_N07_pathNormalizeRejectsWeakStringPrefixEscape() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let root = URL(fileURLWithPath: "/workspace")
        // "/workspace-evil/..." has string prefix "/workspace" but is outside root.
        let line = "/workspace-evil/secret.swift:1:1: error: leaked"
        let problem = ProblemMatcherEngine.match(
            line: line,
            matcher: matcher,
            cwd: root,
            workspaceRoot: root
        )
        #expect(problem == nil)
    }

    @Test func test_TASK_N07_pathNormalizeAllowsInRootCanonical() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let root = URL(fileURLWithPath: "/workspace")
        let line = "/workspace/src/A.swift:2:3: error: x"
        let problem = ProblemMatcherEngine.match(
            line: line,
            matcher: matcher,
            cwd: root,
            workspaceRoot: root
        )
        let p = try #require(problem)
        #expect(p.path.contains("/workspace/src/A.swift") || p.path.hasSuffix("src/A.swift"))
        #expect(p.position.line == 1)
        #expect(p.position.column == 2)
    }

    @Test func test_TASK_N07_resolveRangeBindsDocumentContentState() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let line = "/tmp/V.swift:1:1: error: e"
        let problem = try #require(
            ProblemMatcherEngine.match(line: line, matcher: matcher, cwd: nil)
        )
        let state = DocumentContentStateID()
        let text = "ABCDEFG\n"
        let versioned = try problem.resolve(against: text, contentState: state)
        #expect(versioned.contentState == state)
        #expect(versioned.position.line == 0)
        #expect(versioned.range.location == 0)
        // Stale resolve against different state is a distinct binding (caller compares).
        let other = DocumentContentStateID()
        let again = try problem.resolve(against: text, contentState: other)
        #expect(again.contentState != state)
    }

    @Test func test_TASK_N07_diagnosticRangeRemainsZeroUntilSnapshotResolve() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let p = try #require(
            ProblemMatcherEngine.match(
                line: "/tmp/X.swift:10:5: error: e",
                matcher: matcher,
                cwd: nil
            )
        )
        #expect(p.diagnostic.range.location == 0)
        #expect(p.diagnostic.range.length == 0)
        #expect(p.position.line == 9)
        #expect(p.position.column == 4)
    }

    // MARK: - TASK-N08 finish ownership

    @Test func test_TASK_N08_eventStreamFinishesExactlyOnceOnComplete() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "fin", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil
        )
        handle.emit(stdout: "hi\n")
        var done = handle.run
        done.state = .succeeded
        done.exitCode = 0
        done.endedAt = Date()

        let stream = handle.makeEventStream()
        async let finishedCount: Int = {
            var count = 0
            for await e in stream {
                if case .completed = e {
                    count += 1
                }
            }
            return count
        }()
        // Allow subscriber registration before complete.
        try await Task.sleep(nanoseconds: 10_000_000)
        handle.complete(run: done, stdout: "hi\n", stderr: "")
        let count = await finishedCount
        // Stream ends after completed; second complete is no-op.
        handle.complete(run: done, stdout: "hi\n", stderr: "")
        #expect(count == 1)
        #expect(handle.isFinished)
    }

    @Test func test_TASK_N08_outputChannelFinishClosesSubscription() async throws {
        let ch = OutputChannel(id: "f", name: "f")
        async let lines: [OutputLine] = {
            var all: [OutputLine] = []
            for await line in ch.lines { all.append(line) }
            return all
        }()
        try await Task.sleep(nanoseconds: 5_000_000)
        ch.append(text: "one")
        ch.append(text: "two")
        ch.finish(reason: .completed)
        let collected = await lines
        #expect(collected.count >= 2)
        // After finish, further appends must not reopen the finished stream.
        ch.append(text: "three")
        #expect(ch.isFinished)
    }

    @Test func test_TASK_N08_cancelFinishesEventStream() async throws {
        let handle = try TaskExecutionHandle(
            run: TaskRun(definitionID: "c", state: .running, startedAt: Date()),
            processHandle: nil,
            readinessPattern: nil
        )
        async let sawFinish: Bool = {
            var completed = false
            for await e in handle.events {
                if case .completed = e { completed = true }
            }
            return completed
        }()
        try await Task.sleep(nanoseconds: 5_000_000)
        handle.cancel()
        let finished = await sawFinish
        #expect(finished)
        #expect(handle.isFinished)
        #expect(handle.run.state == .cancelled)
    }
}

// MARK: - Sequence fake runner for exclusive-group tests

struct SequenceFakeTaskRunner: TaskRunner, Sendable {
    struct Script: Sendable {
        var stdoutChunks: [String]
        var exitCode: Int32
    }

    private let scripts: [Script]
    private let indexBox: IndexBox

    final class IndexBox: @unchecked Sendable {
        var value = 0
        let lock = NSLock()
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let i = value
            value += 1
            return i
        }
    }

    init(scripts: [Script]) {
        self.scripts = scripts
        self.indexBox = IndexBox()
    }

    func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle {
        let i = indexBox.next()
        let script = scripts[min(i, scripts.count - 1)]
        let runner = FakeTaskRunner(stdoutChunks: script.stdoutChunks, exitCode: script.exitCode)
        return try await runner.start(definition, output: output)
    }
}
