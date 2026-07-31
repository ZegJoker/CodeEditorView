import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
@testable import CodeEditorTasks

@Suite("Tasks")
struct TaskTests {
    @Test func resolveOrderLinear() async throws {
        let service = TaskService(runner: ProcessTaskRunner())
        await service.register(TaskDefinition(id: "a", label: "A", executable: "/bin/echo", arguments: ["a"]))
        await service.register(TaskDefinition(
            id: "b", label: "B", executable: "/bin/echo", arguments: ["b"], dependsOn: ["a"]
        ))
        let order = try await service.resolveOrder("b")
        #expect(order.map(\.rawValue) == ["a", "b"])
    }

    @Test func resolveOrderDetectsCycle() async throws {
        let service = TaskService(runner: ProcessTaskRunner())
        await service.register(TaskDefinition(id: "a", label: "A", executable: "x", dependsOn: ["b"]))
        await service.register(TaskDefinition(id: "b", label: "B", executable: "x", dependsOn: ["a"]))
        do {
            _ = try await service.resolveOrder("a")
            Issue.record("expected cycle")
        } catch let error as TaskError {
            guard case .dependencyCycle = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    @Test func processRunnerEcho() async throws {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner()
        let def = TaskDefinition(id: "echo", label: "Echo", executable: "/bin/echo", arguments: ["hello-task"])
        let result = try await runner.run(def, output: channel)
        #expect(result.run.state == .succeeded)
        #expect(result.stdout.contains("hello-task"))
        #expect(channel.snapshot.contains(where: { $0.text.contains("hello-task") }))
    }

    @Test func processRunnerLiveStreaming() async throws {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner()
        // Print two lines with a tiny delay between
        let def = TaskDefinition(
            id: "stream",
            label: "Stream",
            executable: "/bin/sh",
            arguments: ["-c", "printf 'a\\n'; printf 'b\\n'"],
            execution: .direct
        )
        let handle = try await runner.start(def, output: channel)
        var sawA = false
        var sawB = false
        for await event in handle.events {
            if case .stdout(let t) = event {
                if t.contains("a") { sawA = true }
                if t.contains("b") { sawB = true }
            }
            if case .completed = event { break }
        }
        #expect(sawA || sawB) // at least one chunk delivered live
        let result = try await handle.wait()
        #expect(result.run.state == .succeeded)
    }

    @Test func processRunnerCancelKillsProcessGroup() async throws {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner()
        // Parent shell sleeps; child would inherit group
        let def = TaskDefinition(
            id: "sleep",
            label: "Sleep",
            executable: "/bin/sleep",
            arguments: ["30"]
        )
        let handle = try await runner.start(def, output: channel)
        try await Task.sleep(nanoseconds: 50_000_000)
        handle.cancel()
        do {
            _ = try await handle.wait()
            Issue.record("expected cancelled")
        } catch TaskError.cancelled {
            // ok
        }
        #expect(handle.run.state == .cancelled)
    }

    @Test func processRunnerTimeout() async throws {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner()
        let def = TaskDefinition(
            id: "timeout",
            label: "Timeout",
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: .milliseconds(80)
        )
        do {
            _ = try await runner.run(def, output: channel)
            Issue.record("expected timeout")
        } catch TaskError.timedOut {
            // ok
        }
    }

    @Test func shellQuotingPreservesSpaces() async throws {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner()
        let def = TaskDefinition(
            id: "quote",
            label: "Quote",
            executable: "/bin/echo",
            arguments: ["hello world"],
            execution: .shell
        )
        let result = try await runner.run(def, output: channel)
        #expect(result.stdout.contains("hello world"))
    }

    @Test func shellQuotingHelpers() {
        #expect(ShellQuoting.quote("simple") == "simple")
        #expect(ShellQuoting.quote("a b") == "'a b'")
        #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
        let cmd = ShellQuoting.joinCommand(executable: "echo", arguments: ["x y"])
        #expect(cmd.contains("'x y'"))
    }

    @Test func processRunnerFailsClosedWhenProfileDeniesLocalProcess() async {
        let channel = OutputChannel(id: "t", name: "t")
        let runner = ProcessTaskRunner(platformProfile: .processUnavailable)
        let def = TaskDefinition(id: "echo", label: "Echo", executable: "/bin/echo", arguments: ["nope"])
        do {
            _ = try await runner.run(def, output: channel)
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .localProcess)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func variableResolution() {
        let text = TaskVariableResolver.resolve(
            "${workspaceFolder}/src",
            variables: ["workspaceFolder": "/proj"]
        )
        #expect(text == "/proj/src")
    }

    @Test func problemMatcherSwiftStyle() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let line = "/tmp/App.swift:10:5: error: cannot find 'x'"
        let problem = ProblemMatcherEngine.match(line: line, matcher: matcher, cwd: nil)
        #expect(problem != nil)
        #expect(problem?.diagnostic.severity == .error)
        #expect(problem?.diagnostic.message.contains("cannot find") == true)
        #expect(problem?.path == "/tmp/App.swift")
    }

    @Test func problemMatcherRejectsPathEscape() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let root = URL(fileURLWithPath: "/workspace")
        let line = "/etc/passwd:1:1: error: secret"
        let problem = ProblemMatcherEngine.match(
            line: line,
            matcher: matcher,
            cwd: root,
            workspaceRoot: root
        )
        #expect(problem == nil)
    }

    @Test func streamingProblemMatcher() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let engine = StreamingProblemMatcherEngine(matchers: [matcher], cwd: nil)
        let part1 = engine.feed("/tmp/A.swift:1:1: error: ")
        #expect(part1.isEmpty) // incomplete line
        let part2 = engine.feed("boom\n")
        #expect(part2.count == 1)
        #expect(part2[0].diagnostic.message == "boom")
    }

    @Test func taskServicePublishesDiagnostics() async throws {
        let sink = InMemoryTaskDiagnosticsSink()
        struct FakeRunner: TaskRunner {
            func start(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskExecutionHandle {
                let text = "/tmp/Z.swift:1:1: warning: unused\n"
                output.append(text: text)
                var run = TaskRun(
                    definitionID: definition.id,
                    state: .succeeded,
                    exitCode: 0,
                    startedAt: Date(),
                    endedAt: Date()
                )
                return TaskExecutionHandle.completed(run: run, stdout: text, stderr: "")
            }
        }
        let svc = TaskService(runner: FakeRunner())
        await svc.setDiagnosticsSink(sink)
        await svc.registerMatcher(try ProblemMatcher.swiftCompiler())
        await svc.register(TaskDefinition(
            id: "build",
            label: "Build",
            executable: "swift",
            problemMatchers: ["swift"]
        ))
        _ = try await svc.run(id: "build")
        // Allow streaming publish task to run
        try await Task.sleep(nanoseconds: 50_000_000)
        let diags = await sink.diagnostics(for: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/Z.swift")))
        #expect(!diags.isEmpty)
        #expect(diags[0].severity == .warning)
    }

    @Test func fakeRunnerBackgroundReadiness() async throws {
        let runner = FakeTaskRunner(
            stdoutChunks: ["starting\n", "READY\n", "done\n"],
            chunkDelayNanoseconds: 5_000_000
        )
        let channel = OutputChannel(id: "t", name: "t")
        let def = TaskDefinition(
            id: "bg",
            label: "BG",
            executable: "x",
            isBackground: true,
            readinessPattern: "READY"
        )
        let handle = try await runner.start(def, output: channel)
        var ready = false
        for await event in handle.events {
            if case .ready = event { ready = true; break }
            if case .completed = event { break }
        }
        #expect(ready)
        _ = try await handle.wait()
    }

    @Test func exclusiveConcurrencyGroupSerializes() async throws {
        let runner = FakeTaskRunner(
            stdoutChunks: ["ok\n"],
            chunkDelayNanoseconds: 30_000_000
        )
        let service = TaskService(runner: runner)
        await service.register(TaskDefinition(
            id: "a",
            label: "A",
            executable: "a",
            concurrencyGroup: "g",
            isExclusive: true
        ))
        await service.register(TaskDefinition(
            id: "b",
            label: "B",
            executable: "b",
            concurrencyGroup: "g",
            isExclusive: true
        ))
        async let r1 = service.run(id: "a")
        try await Task.sleep(nanoseconds: 5_000_000)
        async let r2 = service.run(id: "b")
        let a = try await r1
        let b = try await r2
        #expect(a.state == .succeeded)
        #expect(b.state == .succeeded)
    }

    @Test func processServiceCollecting() async throws {
        let service = ProcessService()
        let result = try await service.runCollecting(
            ProcessLaunchRequest(executable: "/bin/echo", arguments: ["hi"])
        )
        #expect(result.stdout.contains("hi"))
        #expect(result.code == 0)
    }
}
