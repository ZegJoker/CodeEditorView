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

    @Test func problemMatcherSwiftStyle() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let line = "/tmp/App.swift:10:5: error: cannot find 'x'"
        let problem = ProblemMatcherEngine.match(line: line, matcher: matcher, cwd: nil)
        #expect(problem != nil)
        #expect(problem?.diagnostic.severity == .error)
        #expect(problem?.diagnostic.message.contains("cannot find") == true)
        #expect(problem?.path == "/tmp/App.swift")
    }

    @Test func taskServicePublishesDiagnostics() async throws {
        let sink = InMemoryTaskDiagnosticsSink()
        let service = TaskService(runner: ProcessTaskRunner())
        await service.setDiagnosticsSink(sink)
        try await service.registerMatcher(ProblemMatcher.swiftCompiler())

        // Fake runner that emits compiler-like output
        struct FakeRunner: TaskRunner {
            func run(_ definition: TaskDefinition, output: OutputChannel) async throws -> TaskRunResult {
                let text = "/tmp/Z.swift:1:1: warning: unused\n"
                output.append(text: text)
                var run = TaskRun(definitionID: definition.id, state: .succeeded, exitCode: 0, startedAt: Date(), endedAt: Date())
                return TaskRunResult(run: run, stdout: text, stderr: "")
            }
        }
        let svc = TaskService(runner: FakeRunner())
        await svc.setDiagnosticsSink(sink)
        try await svc.registerMatcher(ProblemMatcher.swiftCompiler())
        await svc.register(TaskDefinition(
            id: "build",
            label: "Build",
            executable: "swift",
            problemMatchers: ["swift"]
        ))
        _ = try await svc.run(id: "build")
        let diags = await sink.diagnostics(for: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/Z.swift")))
        #expect(!diags.isEmpty)
        #expect(diags[0].severity == .warning)
    }
}
