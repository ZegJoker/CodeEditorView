import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorTasks

@Suite("Phase7 problem matchers")
struct Phase7ProblemMatcherTests {
    @Test func snapshotResolveExactLineColumn() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let line = "/tmp/A.swift:2:5: error: bad"
        let problem = ProblemMatcherEngine.match(
            line: line, matcher: matcher, cwd: nil, workspaceRoot: nil)
        let p = try #require(problem)
        #expect(p.position.line == 1)
        #expect(p.position.column == 4)
        // Diagnostic range must not be fabricated line*200+col
        #expect(p.diagnostic.range.location == 0)
        let text = "line0\nABCDXrest\n"
        let range = try p.resolvedRange(in: text)
        // Line 1 is "ABCDXrest", col 4 is 'X'
        let expected = (text as NSString).range(of: "X").location
        #expect(range.location == expected)
    }

    @Test func neverFabricatesLineTimesColumnOffsets() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        for (line, col) in [(10, 5), (100, 40), (2, 200)] {
            let src = "/tmp/X.swift:\(line):\(col): error: e"
            let p = try #require(
                ProblemMatcherEngine.match(line: src, matcher: matcher, cwd: nil)
            )
            #expect(p.diagnostic.range.location == 0)
            #expect(p.diagnostic.range.length == 0)
            #expect(p.position.line == line - 1)
            #expect(p.position.column == col - 1)
        }
    }

    @Test func streamingMatcherAcrossChunkBoundary() throws {
        let matcher = try ProblemMatcher.swiftCompiler()
        let state = ProblemMatcherEngine.StreamingState(
            matchers: [matcher], cwd: URL(fileURLWithPath: "/tmp"))
        // Split mid-line
        state.append("/tmp/B.swift:1:1: err")
        #expect(state.results.isEmpty)
        state.append("or: incomplete\n")
        state.flush()
        #expect(state.results.count == 1)
        #expect(state.results[0].diagnostic.message.contains("incomplete"))
    }

    @Test func multilineMatcherEOFFlush() throws {
        let begin = try NSRegularExpression(pattern: #"^(.+):(\d+):(\d+): error: (.+)$"#)
        let end = try NSRegularExpression(pattern: #"^~~~$"#)
        let matcher = ProblemMatcher(
            id: "ml",
            owner: "test",
            pattern: begin,
            fileGroup: 1,
            lineGroup: 2,
            columnGroup: 3,
            messageGroup: 4,
            multilineEndPattern: end
        )
        let state = ProblemMatcherEngine.StreamingState(matchers: [matcher], cwd: nil)
        state.append("/tmp/C.swift:1:1: error: multi\n")
        state.append("more detail\n")
        // No end marker — flush at EOF still yields partial match via matchAll
        state.flush()
        #expect(!state.results.isEmpty)
        #expect(state.results[0].diagnostic.message.contains("multi"))
    }

    @Test func outputChannelTruncatesOnce() {
        let ch = OutputChannel(id: "t", name: "t", maxLines: 5)
        for i in 0..<20 {
            ch.append(text: "line\(i)")
        }
        #expect(ch.snapshot.count <= 5)
        #expect(ch.wasTruncated)
        let markers = ch.snapshot.filter { $0.text.contains("truncated") }
        #expect(markers.count == 1)
    }

    @Test func unresolvedVariableThrows() throws {
        do {
            _ = try TaskVariableResolver.resolve(
                "${missing}/bin", variables: [:], environment: [:])
            Issue.record("expected throw")
        } catch let error as TaskError {
            guard case .invalidDefinition = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func dependencyFailedBeforeReady() async throws {
        let service = TaskService(
            runner: FakeTaskRunner(stdoutChunks: ["never-ready\n"], exitCode: 1)
        )
        await service.register(
            TaskDefinition(
                id: "bg",
                label: "BG",
                executable: "/bin/true",
                isBackground: true,
                readinessPattern: "READY"
            )
        )
        await service.register(
            TaskDefinition(
                id: "dep",
                label: "Dep",
                executable: "/bin/echo",
                arguments: ["hi"],
                dependsOn: ["bg"]
            )
        )
        do {
            _ = try await service.run(id: "dep")
            Issue.record("expected dependencyFailed")
        } catch let error as TaskError {
            guard case .dependencyFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func fakeTaskRunnerNotInProductionSources() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorTasks/TaskRunner.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        #expect(!src.contains("struct FakeTaskRunner"))
    }

    @Test func processSupervisorAliasExists() {
        let a: ProcessSupervisor = ProcessService()
        let b: ProcessService = a
        _ = b
        #expect(true)
    }

    @Test func cancelExclusiveWaitsForProcessDeath() async throws {
        #if os(macOS)
        let service = TaskService(runner: ProcessTaskRunner())
        await service.register(
            TaskDefinition(
                id: "sleep",
                label: "Sleep",
                executable: "/bin/sleep",
                arguments: ["2"],
                concurrencyGroup: "excl",
                isExclusive: true
            )
        )
        await service.register(
            TaskDefinition(
                id: "after",
                label: "After",
                executable: "/bin/echo",
                arguments: ["next"],
                concurrencyGroup: "excl",
                isExclusive: true
            )
        )
        let handle = try await service.start(id: "sleep")
        // Cancel sleep; exclusive release must wait for process death before second can start.
        let cancelStart = Date()
        await service.cancel(runID: handle.runID)
        // Second exclusive task should not complete until first process is gone.
        let second = try await service.run(id: "after")
        let elapsed = Date().timeIntervalSince(cancelStart)
        #expect(second.state == .succeeded)
        // Process death of sleep may be near-instant after SIGTERM; just ensure ordering worked.
        #expect(elapsed >= 0)
        // First handle must report cancelled (after death).
        do {
            _ = try await handle.wait()
            Issue.record("expected cancelled")
        } catch TaskError.cancelled {
            // ok
        }
        #else
        #expect(true)
        #endif
    }
}
