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
        let token = registry.register(FileTreeNavigatorContribution())
        #expect(registry.contributions(for: .navigator).count == 1)
        registry.unregister(id: "workbench.navigator.files")
        #expect(registry.contributions(for: .navigator).isEmpty)
        token.dispose()
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
