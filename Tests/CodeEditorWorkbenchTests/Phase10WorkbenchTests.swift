import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorSourceControl
import CodeEditorTasks
import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorWorkbench

@Suite("Phase10 workbench chrome")
@MainActor
struct Phase10WorkbenchTests {
    @Test func navigatorInventoryCompleteOnDefaultWorkbench() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p10-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        let ids = Set(model.contributionRegistry.allContributions().map(\.id))
        #expect(WorkbenchNavigatorID.isCovered(by: ids))
        #expect(ids.contains(WorkbenchNavigatorID.files.rawValue))
        #expect(ids.contains(WorkbenchNavigatorID.symbols.rawValue))
        #expect(ids.contains(WorkbenchNavigatorID.breakpoints.rawValue))
    }

    @Test func schemeResolvesBuildTestRunTasks() throws {
        let schemes = WorkbenchSchemeModel()
        schemes.setSchemes([
            WorkbenchScheme(id: "s", name: "S", buildTaskID: "b", testTaskID: "t", runTaskID: "r")
        ])
        schemes.selectedSchemeID = "s"
        #expect(try schemes.taskID(for: .build) == "b")
        #expect(try schemes.taskID(for: .test) == "t")
        #expect(try schemes.taskID(for: .run) == "r")
    }

    @Test func activityCancelRemovesItem() {
        let activity = WorkbenchActivityModel()
        activity.begin(id: "idx", title: "Indexing")
        #expect(activity.isBusy)
        #expect(activity.cancel(id: "idx"))
        #expect(!activity.isBusy)
        #expect(activity.cancelledIDs.contains("idx"))
    }

    @Test func statusLineColumnUsesLineIndexNotScanSemantics() {
        let text = "aaa\nbbb\nccc"
        // Offset of first 'c' is after "aaa\nbbb\n" = 8
        let lc = WorkbenchStatusMetrics.lineColumn(text: text, utf16Offset: 8)
        #expect(lc.line == 3)
        #expect(lc.column == 1)
        let label = WorkbenchStatusMetrics.label(text: text, utf16Offset: 9)
        #expect(label.contains("Ln 3"))
    }

    @Test func openQuicklyParsesPathLineColumn() {
        let p = OpenQuicklyModel.parseLocationQuery("Sources/Main.swift:12:4")
        #expect(p.path == "Sources/Main.swift")
        #expect(p.line == 11)
        #expect(p.column == 3)
        let p2 = OpenQuicklyModel.parseLocationQuery("Main.swift:5")
        #expect(p2.line == 4)
        #expect(p2.column == nil)
    }

    @Test func openQuicklyModesFilterCorpus() {
        let m = OpenQuicklyModel()
        m.symbolItems = [
            OpenQuicklyItem(uri: nil, name: "Foo", path: "A.swift", mode: .symbol, line: 0)
        ]
        m.commandItems = [
            OpenQuicklyItem(uri: nil, name: "Build", path: "workbench.scheme.build", mode: .command)
        ]
        m.mode = .symbol
        m.query = "Fo"
        #expect(m.results.count == 1)
        #expect(m.results[0].name == "Foo")
        m.mode = .command
        m.query = "Bui"
        #expect(m.results.count == 1)
        #expect(m.results[0].mode == .command)
    }

    @Test func breakpointsAndDebugModels() {
        let bp = WorkbenchBreakpointsModel()
        bp.upsert(WorkbenchBreakpointItem(path: "Main.swift", line: 10))
        #expect(bp.breakpoints.count == 1)
        bp.setEnabled(id: bp.breakpoints[0].id, enabled: false)
        #expect(bp.breakpoints[0].enabled == false)

        let dbg = WorkbenchDebugModel()
        dbg.upsert(id: "1", name: "LLDB", state: "stopped")
        #expect(dbg.sessions.count == 1)
    }

    @Test func testsModelMarksRunning() {
        let t = WorkbenchTestsModel()
        t.setTests([WorkbenchTestItem(id: "a", name: "testA")])
        t.markRunning(taskID: "test")
        #expect(t.tests[0].state == "running")
        #expect(t.lastRunTaskID == "test")
    }

    @Test func chromeCommandsAreDistinctCommandIDs() {
        let ids = WorkbenchChromeCommand.allCases.map(\.commandID.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("workbench.scheme.build"))
    }

    @Test func tabPinSemantics() {
        let uri = DocumentURI(rawValue: "file:///tmp/t.swift")
        var tab = EditorTab(
            sessionID: EditorSessionID(),
            documentID: DocumentID(),
            documentURI: uri,
            isPreview: true
        )
        WorkbenchTabSemantics.pin(tab: &tab)
        #expect(tab.isPinned)
        #expect(!tab.isPreview)
        var preview = EditorTab(
            sessionID: EditorSessionID(),
            documentID: DocumentID(),
            documentURI: uri,
            isPreview: true
        )
        WorkbenchTabSemantics.promotePreviewIfNeeded(tab: &preview)
        #expect(!preview.isPreview)
    }

    @Test func symbolsModelFilters() {
        let s = WorkbenchSymbolsModel()
        s.setSymbols([
            WorkbenchSymbolItem(name: "Alpha", kind: "func", path: "A.swift", line: 0),
            WorkbenchSymbolItem(name: "Beta", kind: "type", path: "B.swift", line: 1),
        ])
        s.filter = "alp"
        #expect(s.filtered.count == 1)
        #expect(s.filtered[0].name == "Alpha")
    }

    @Test func defaultWorkbenchHasSchemes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p10-sch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace)
        #expect(model.schemes.selectedScheme != nil)
        #expect(try model.schemes.taskID(for: .build) == "build")
    }
}
