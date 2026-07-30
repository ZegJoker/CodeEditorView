import Foundation
import Testing
import CodeEditorDocuments
import CodeEditorWorkspace
@testable import CodeEditorWorkbench

@Suite("Document view registry")
@MainActor
struct DocumentViewRegistryTests {
    @Test func picksImageAndPDFOverText() {
        let registry = DocumentViewRegistry()
        registry.register(TextDocumentViewProvider())
        registry.register(ImageDocumentViewProvider())
        registry.register(PDFDocumentViewProvider())
        #expect(registry.provider(for: "png")?.id == "workbench.document.image")
        #expect(registry.provider(for: "PDF")?.id == "workbench.document.pdf")
        #expect(registry.provider(for: "swift")?.id == "workbench.document.text")
    }
}

@Suite("Contribution registry")
@MainActor
struct WorkbenchContributionRegistryTests {
    @Test func registerAndListBySlot() {
        let registry = WorkbenchContributionRegistry()
        let before = registry.revision
        let token = registry.register(FileTreeNavigatorContribution())
        #expect(registry.revision > before)
        #expect(registry.contributions(for: .navigator).count == 1)
        registry.unregister(id: "workbench.navigator.files")
        #expect(registry.contributions(for: .navigator).isEmpty)
        token.dispose()
    }

    @Test func workbenchModelSelectsNavigatorAndUtility() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-Nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = WorkbenchModel(workspace: workspace, configuration: .xcodeLike)
        #expect(model.activeNavigatorID == "workbench.navigator.files")
        #expect(model.contributionRegistry.contributions(for: .utility).count >= 3)
        model.selectUtility(id: "workbench.utility.terminal")
        #expect(model.activeUtilityID == "workbench.utility.terminal")
        #expect(model.isUtilityVisible)
        model.selectNavigator(id: "workbench.navigator.files")
        #expect(model.isNavigatorVisible)
    }
}

@Suite("Editor client registry")
@MainActor
struct EditorClientRegistryTests {
    @Test func activeClientFollowsSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        try "hi".data(using: .utf8)!.write(to: file)

        let workspace = try await Workspace.local(rootDirectories: [root])
        let opened = try await workspace.openInActivePane(uri: DocumentURI(fileURL: file))
        let registry = WorkbenchEditorClientRegistry()
        let client = SessionCommandClient(document: opened.document, session: opened.session)
        registry.register(sessionID: opened.session.id, client: client)
        #expect(registry.activeClient(workspace: workspace) != nil)
        #expect(registry.activeClient(workspace: workspace)?.documentID == opened.document.id)
    }
}

@Suite("Open Quickly")
@MainActor
struct OpenQuicklyModelTests {
    @Test func filtersByName() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OQ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".data(using: .utf8)!.write(to: root.appendingPathComponent("Alpha.swift"))
        try "b".data(using: .utf8)!.write(to: root.appendingPathComponent("Beta.md"))

        let workspace = try await Workspace.local(rootDirectories: [root])
        let model = OpenQuicklyModel()
        await model.recompute(workspace: workspace)
        model.query = "alpha"
        #expect(model.results.count == 1)
        #expect(model.results[0].name == "Alpha.swift")
    }
}

@Suite("Workbench open and create")
@MainActor
struct WorkbenchOpenCreateTests {
    @Test func openInActivePaneCreatesTabAndBumpsRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-Open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.swift")
        try "print(1)\n".data(using: .utf8)!.write(to: file)

        let workspace = try await Workspace.local(rootDirectories: [root])
        let before = workspace.revision
        let opened = try await workspace.openInActivePane(
            uri: DocumentURI(fileURL: file),
            preview: false
        )
        #expect(workspace.revision > before)
        #expect(workspace.panes[workspace.activePaneID!]?.tabs.count == 1)
        #expect(opened.document.uri.fileURL?.lastPathComponent == "Main.swift")
        #expect(workspace.documents.document(id: opened.document.id) != nil)
        #expect(workspace.sessions[opened.session.id] != nil)
    }

    @Test func createFileAppearsUnderRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WB-Create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = try await Workspace.local(rootDirectories: [root])
        let rootID = workspace.fileTree.roots[0].id
        let parent = WorkspaceItemID(rootID: rootID, path: "")
        let item = try await workspace.createFile(
            in: parent,
            name: "New.swift",
            contents: Data("// hi\n".utf8)
        )
        #expect(item.name == "New.swift")
        let kids = try await workspace.fileTree.children(of: parent)
        #expect(kids.contains { $0.name == "New.swift" })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("New.swift").path))
    }
}
