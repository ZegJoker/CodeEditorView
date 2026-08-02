import CodeEditorCommands
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
}
