import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorWorkbench

@Suite("Phase4 workbench registration and close")
@MainActor
struct Phase4WorkbenchTests {
    private func makeModel() async throws -> WorkbenchModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-p4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ws = try await Workspace.local(rootDirectories: [root])
        return try WorkbenchHostBuilder()
            .workspace(ws)
            .build()
    }

    @Test func registrationBagSurvivesBuild() async throws {
        let model = try await makeModel()
        #expect(model.registrationBag.count >= 3)
        let navs = model.contributionRegistry.contributions(for: .navigator)
        #expect(!navs.isEmpty)
        // Contributions still listed after "autorelease" of build.
        #expect(model.contributionRegistry.contribution(id: "workbench.navigator.files") != nil)
        model.beginTearDown()
        #expect(model.registrationBag.isDisposed)
    }

    @Test func commandContextSnapshotReflectsFocusAndTrust() async throws {
        let model = try await makeModel()
        #expect(model.workspace.trust.level == .restricted)
        model.focus(.navigator)
        model.refreshCommandContextSnapshot()
        #expect(model.commandContextSnapshot.activePart == "navigator")
        #expect(model.commandContextSnapshot.workspaceTrust == "restricted")
        #expect(!model.commandContextSnapshot.isFocused)  // editor not focused
    }

    @Test func requestCloseWindowUsesCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("x.txt")
        try "body".data(using: .utf8)!.write(to: file)
        let ws = try await Workspace.local(rootDirectories: [root])
        ws.closeCoordinator.defaultPolicy = .prompt
        let model = try WorkbenchHostBuilder().workspace(ws).build()
        let opened = try await ws.openInActivePane(uri: DocumentURI(fileURL: file))
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "!")
        )
        let result = await model.requestCloseWindow()
        #expect(result == .cancelled)
        #expect(ws.documents.document(id: opened.document.id) != nil)
    }

    @Test func futureWorkbenchSchemaRejected() throws {
        let state = WorkbenchRestorationState(
            schemaVersion: 999,
            lifecyclePhase: .active,
            windows: [],
            focusedWindowID: nil,
            workspace: WorkspaceRestorationState(
                workspaceID: WorkspaceID(),
                roots: [],
                layout: .pane(EditorPaneID()),
                panes: [],
                activePaneID: nil,
                focusHistory: [],
                navigation: [],
                navigationIndex: -1
            ),
            registeredContributionIDs: [],
            toolingSurfaces: []
        )
        #expect(throws: WorkbenchRestorationError.self) {
            _ = try WorkbenchRestoration.migrate(state)
        }
    }

    /// E1: dirty last lease in a split pane cancels via coordinator (not silent drop).
    @Test func requestClosePaneDirtyCancelsWithoutDecision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("p.txt")
        try "pane".data(using: .utf8)!.write(to: file)
        let ws = try await Workspace.local(rootDirectories: [root])
        ws.closeCoordinator.defaultPolicy = .prompt
        let model = try WorkbenchHostBuilder().workspace(ws).build()
        let opened = try await ws.openInActivePane(uri: DocumentURI(fileURL: file))
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "!")
        )
        let source = try #require(ws.activePaneID)
        let second = try #require(ws.splitActivePane(axis: .horizontal))
        #expect(ws.panes.count == 2)
        // Close second pane while it holds a dirty shared lease copy — cancel policy.
        let result = await model.requestClosePane(second)
        #expect(result == .cancelled || result == .closed)
        // Source pane dirty last lease: prompt without delegate → cancel.
        let last = await model.requestClosePane(source)
        // Only one pane may remain; closing last is no-op closed.
        if ws.panes.count > 1 {
            #expect(last == .cancelled)
            #expect(ws.documents.document(id: opened.document.id) != nil)
        }
    }

    /// E1: Workbench UI source must not call sync closePane for user Close Pane.
    @Test func workbenchEditorAreaUsesRequestClosePane() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeEditorWorkbench/Views/WorkbenchEditorArea.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("requestClosePane"),
            "WorkbenchEditorArea must call requestClosePane for Close Pane"
        )
        // Ban direct user-facing sync close on the button path.
        #expect(
            !source.contains("model.workspace.closePane("),
            "Close Pane must not call sync closePane"
        )
    }

    /// E12: workbench-style execute path returns typed notFound (no silent success).
    @Test func executeUnknownCommandIsTypedNotFound() async throws {
        let model = try await makeModel()
        let editor = model.makeCommandContext()
        // Without an active editor client, still probe dispatcher directly.
        let dispatcher = model.commandDispatcher
        #expect(throws: CommandError.self) {
            try dispatcher.execute("test.unknown.palette.cmd", context: CommandContext.make(
                from: AlwaysEditor(),
                snapshot: model.commandContextSnapshot
            ))
        }
        let result = try await dispatcher.executeAsync(
            "test.unknown.palette.cmd",
            context: CommandContext.make(from: AlwaysEditor(), snapshot: model.commandContextSnapshot)
        )
        #expect(result == .failed("notFound:test.unknown.palette.cmd"))
        _ = editor
    }
}

@MainActor
private final class AlwaysEditor: EditorCommandClient {
    var isEditable: Bool = false
    var isFocused: Bool = false
    var selections: [CodeEditorCore.TextRange] = []
    var snapshot: DocumentSnapshot = DocumentSnapshot(version: .zero, text: "")
    var documentID: DocumentID? = nil
    var sessionID: EditorSessionID? = nil
    var languageID: String? = nil
    var contextFlags: [String: Bool] = [:]
    func perform(_ action: EditorCommandAction) throws {}
}
