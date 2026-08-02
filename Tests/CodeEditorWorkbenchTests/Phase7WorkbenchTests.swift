import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorTasks
import Foundation
import Testing

@testable import CodeEditorWorkbench

@Suite("Phase7 workbench models")
@MainActor
struct Phase7WorkbenchModelTests {
    @Test func taskProblemsBridgeIngestsMatched() throws {
        let bridge = WorkbenchTaskProblemsBridge()
        let matcher = try ProblemMatcher.swiftCompiler()
        let p = try #require(
            ProblemMatcherEngine.match(
                line: "/src/A.swift:3:2: error: nope",
                matcher: matcher,
                cwd: nil
            )
        )
        bridge.ingest(matched: [p], runID: "run1")
        #expect(bridge.problems.count == 1)
        #expect(bridge.problems[0].line == 2)
        #expect(bridge.problems[0].message.contains("nope"))
    }

    @Test func debugModelTracksSessions() {
        let model = WorkbenchDebugModel()
        model.upsert(id: "1", name: "LLDB", state: "stopped")
        model.upsert(id: "1", name: "LLDB", state: "running")
        #expect(model.sessions.count == 1)
        #expect(model.sessions[0].state == "running")
        model.remove(id: "1")
        #expect(model.sessions.isEmpty)
    }

    @Test func scmModelFailsClosedWhenUntrusted() async {
        let model = WorkbenchSCMModel()
        model.trusted = false
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-scm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = GitCLIProvider(repositoryRoot: root, trusted: false)
        await model.refresh(provider: provider)
        #expect(model.statuses.isEmpty)
        #expect(model.errorMessage != nil)
    }
}
