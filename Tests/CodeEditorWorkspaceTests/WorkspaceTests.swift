import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorWorkspace

@Suite("Local workspace file system")
struct LocalFSTests {
    @Test func lazyChildrenOnlyListsWhenRequested() async throws {
        let root = try makeTempRoot(files: ["a.txt": "a", "sub/b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try LocalWorkspaceFileSystem(rootDirectories: [root])
        #expect(fs.directoryListCount == 0)
        let rootID = try #require(fs.roots.first).id
        let rootItem = WorkspaceItemID(rootID: rootID, path: "")
        let kids = try await fs.children(of: rootItem)
        #expect(fs.directoryListCount == 1)
        #expect(kids.contains { $0.name == "a.txt" })
        #expect(kids.contains { $0.name == "sub" && $0.isDirectory })
        // Nested not listed until asked.
        let sub = try #require(kids.first { $0.name == "sub" })
        _ = try await fs.children(of: sub.id)
        #expect(fs.directoryListCount == 2)
    }

    @Test func createMoveCopyDelete() async throws {
        let root = try makeTempRoot(files: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try LocalWorkspaceFileSystem(rootDirectories: [root])
        let rootID = try #require(fs.roots.first).id
        let rootItem = WorkspaceItemID(rootID: rootID, path: "")
        let file = try await fs.createFile(in: rootItem, name: "x.txt", contents: Data("hi".utf8))
        #expect(file.name == "x.txt")
        let dir = try await fs.createDirectory(in: rootItem, name: "d")
        let moved = try await fs.move(item: file.id, to: dir.id, newName: "y.txt")
        #expect(moved.id.path == "d/y.txt")
        let copied = try await fs.copy(item: moved.id, to: rootItem, newName: "z.txt")
        #expect(copied.id.path == "z.txt")
        try await fs.delete(item: copied.id)
        let kids = try await fs.children(of: rootItem)
        #expect(!kids.contains { $0.name == "z.txt" })
    }
}

@Suite("Layout normalize")
@MainActor
struct LayoutNormalizeTests {
    @Test func singleChildSplitCollapses() {
        let a = EditorPaneID()
        let store = EditorLayoutStore(
            root: .split(
                id: EditorSplitID(),
                axis: .horizontal,
                children: [.pane(a)],
                fractions: [1]
            )
        )
        if case .pane(let id) = store.root {
            #expect(id == a)
        } else {
            Issue.record("Expected single pane after normalize")
        }
    }

    @Test func fractionsRenormalize() {
        let a = EditorPaneID()
        let b = EditorPaneID()
        let sid = EditorSplitID()
        let store = EditorLayoutStore(
            root: .split(id: sid, axis: .vertical, children: [.pane(a), .pane(b)], fractions: [1, 1])
        )
        store.setFractions(split: sid, fractions: [2, 2])
        if case .split(_, _, _, let fracs) = store.root {
            #expect(abs(fracs.reduce(0, +) - 1.0) < 0.0001)
            #expect(fracs.count == 2)
        } else {
            Issue.record("Expected split")
        }
    }

    @Test func closeKeepsAtLeastOnePane() {
        let a = EditorPaneID()
        let store = EditorLayoutStore(singlePane: a)
        store.close(pane: a)
        #expect(store.allPaneIDs().count == 1)
    }
}

@Suite("Preview tab policy")
@MainActor
struct PreviewTabPolicyTests {
    @Test func secondPreviewReplacesFirst() {
        let pane = EditorPane()
        let d1 = DocumentID()
        let d2 = DocumentID()
        let t1 = pane.open(sessionID: EditorSessionID(), documentID: d1, documentURI: "inmemory:1", preview: true)
        #expect(t1.tab.isPreview)
        #expect(t1.replacedPreview == nil)
        let t2 = pane.open(sessionID: EditorSessionID(), documentID: d2, documentURI: "inmemory:2", preview: true)
        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0].id == t2.tab.id)
        #expect(pane.previewTabID == t2.tab.id)
        #expect(t2.replacedPreview?.id == t1.tab.id)
    }

    @Test func pinPromotesPreview() {
        let pane = EditorPane()
        let tab = pane.open(
            sessionID: EditorSessionID(), documentID: DocumentID(), documentURI: "inmemory:x", preview: true)
        pane.pin(tab: tab.tab.id)
        #expect(pane.tabs[0].isPinned)
        #expect(!pane.tabs[0].isPreview)
        #expect(pane.previewTabID == nil)
    }

    @Test func keepOpenThenSecondPreviewDoesNotReplace() {
        let pane = EditorPane()
        let d1 = DocumentID()
        let d2 = DocumentID()
        let t1 = pane.open(sessionID: EditorSessionID(), documentID: d1, documentURI: "inmemory:1", preview: true)
        pane.promotePreviewIfNeeded(tab: t1.tab.id)
        #expect(!pane.tabs[0].isPreview)
        #expect(pane.previewTabID == nil)

        let t2 = pane.open(sessionID: EditorSessionID(), documentID: d2, documentURI: "inmemory:2", preview: true)
        #expect(pane.tabs.count == 2)
        #expect(pane.tabs.contains { $0.id == t1.tab.id && !$0.isPreview })
        #expect(pane.tabs.contains { $0.id == t2.tab.id && $0.isPreview })
        #expect(pane.previewTabID == t2.tab.id)
    }

    @Test func permanentOpenReusesAndPromotesPreview() {
        let pane = EditorPane()
        let d1 = DocumentID()
        let first = pane.open(sessionID: EditorSessionID(), documentID: d1, documentURI: "inmemory:1", preview: true)
        #expect(first.tab.isPreview)
        let second = pane.open(
            sessionID: EditorSessionID(),
            documentID: d1,
            documentURI: "inmemory:1",
            preview: false
        )
        #expect(pane.tabs.count == 1)
        #expect(second.tab.id == first.tab.id)
        #expect(!second.tab.isPreview)
        #expect(pane.previewTabID == nil)
    }

    @Test func workspaceDoubleOpenPromotesPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewPromote-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("A.swift")
        try "let x = 1\n".data(using: .utf8)!.write(to: file)
        let other = root.appendingPathComponent("B.swift")
        try "let y = 2\n".data(using: .utf8)!.write(to: other)

        let workspace = try await Workspace.local(rootDirectories: [root])
        let a = try await workspace.openInActivePane(uri: DocumentURI(fileURL: file), preview: true)
        #expect(a.tab.isPreview)
        // Permanent open of same file (navigator double-click).
        let a2 = try await workspace.openInActivePane(uri: DocumentURI(fileURL: file), preview: false)
        #expect(a2.tab.id == a.tab.id)
        #expect(!a2.tab.isPreview)

        let b = try await workspace.openInActivePane(uri: DocumentURI(fileURL: other), preview: true)
        #expect(workspace.panes[workspace.activePaneID!]!.tabs.count == 2)
        #expect(b.tab.isPreview)
        // A still permanent.
        #expect(workspace.panes.values.flatMap(\.tabs).contains { $0.documentID == a.document.id && !$0.isPreview })
    }
}

@Suite("Navigation history")
@MainActor
struct NavigationHistoryTests {
    @Test func backForward() {
        let history = NavigationHistory()
        history.push(NavigationEntry(documentURI: "inmemory:a"))
        history.push(NavigationEntry(documentURI: "inmemory:b"))
        #expect(history.canGoBack)
        let back = history.back()
        #expect(back?.documentURI.rawValue == "inmemory:a")
        #expect(history.canGoForward)
        let forward = history.forward()
        #expect(forward?.documentURI.rawValue == "inmemory:b")
    }
}

@Suite("Pane split and tabs")
@MainActor
struct PaneSplitAndTabsTests {
    @Test func splitActivePaneClonesSelectedTab() async throws {
        let root = try makeTempRoot(files: ["Main.swift": "print(1)\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let file = root.appendingPathComponent("Main.swift")
        let opened = try await workspace.openInActivePane(
            uri: DocumentURI(fileURL: file),
            preview: false
        )
        let sourcePaneID = try #require(workspace.activePaneID)
        let newPaneID = try #require(workspace.splitActivePane(axis: .horizontal))
        #expect(newPaneID != sourcePaneID)
        #expect(workspace.panes.count == 2)
        let cloned = try #require(workspace.panes[newPaneID])
        #expect(cloned.tabs.count == 1)
        #expect(cloned.tabs[0].documentID == opened.document.id)
        #expect(cloned.tabs[0].sessionID != opened.session.id)
        if case .split(_, let axis, let children, let fracs) = workspace.layout.root {
            #expect(axis == .horizontal)
            #expect(children.count == 2)
            #expect(abs(fracs.reduce(0, +) - 1) < 0.001)
        } else {
            Issue.record("Expected horizontal split")
        }
    }

    @Test func moveTabReordersWithinPane() {
        let pane = EditorPane()
        let a = pane.open(
            sessionID: EditorSessionID(), documentID: DocumentID(), documentURI: "inmemory:a", preview: false)
        let b = pane.open(
            sessionID: EditorSessionID(), documentID: DocumentID(), documentURI: "inmemory:b", preview: false)
        let c = pane.open(
            sessionID: EditorSessionID(), documentID: DocumentID(), documentURI: "inmemory:c", preview: false)
        #expect(pane.tabs.map(\.id) == [a.tab.id, b.tab.id, c.tab.id])
        pane.moveTab(from: 0, to: 2)
        #expect(pane.tabs.map(\.id) == [b.tab.id, c.tab.id, a.tab.id])
    }

    @Test func setSplitFractionsPersists() async throws {
        let root = try makeTempRoot(files: ["a.txt": "a"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let file = root.appendingPathComponent("a.txt")
        _ = try await workspace.openInActivePane(uri: DocumentURI(fileURL: file), preview: false)
        _ = workspace.splitActivePane(axis: .vertical, fraction: 0.4)
        guard case .split(let id, _, _, let before) = workspace.layout.root else {
            Issue.record("Expected split")
            return
        }
        #expect(abs(before[0] - 0.4) < 0.001)
        workspace.setSplitFractions(id, fractions: [0.7, 0.3])
        guard case .split(_, _, _, let after) = workspace.layout.root else {
            Issue.record("Expected split after set")
            return
        }
        #expect(abs(after[0] - 0.7) < 0.001)
        #expect(abs(after[1] - 0.3) < 0.001)
    }
}

@Suite("Workspace headless")
@MainActor
struct WorkspaceHeadlessTests {
    @Test func openDocumentAndTab() async throws {
        let root = try makeTempRoot(files: ["main.swift": "print(1)\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let fileURL = root.appendingPathComponent("main.swift")
        let uri = DocumentURI(fileURL: fileURL)
        let result = try await workspace.openInActivePane(uri: uri, preview: false)
        #expect(result.document.text.contains("print"))
        #expect(workspace.documents.document(id: result.document.id) != nil)
        let activeID = try #require(workspace.activePaneID)
        let pane = try #require(workspace.panes[activeID])
        #expect(pane.tabs.count == 1)
        #expect(pane.selectedTab?.documentID == result.document.id)
    }

    @Test func previewThenOpenSecond() async throws {
        let root = try makeTempRoot(files: ["a.txt": "a", "b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        _ = try await workspace.openInActivePane(
            uri: DocumentURI(fileURL: root.appendingPathComponent("a.txt")), preview: true)
        _ = try await workspace.openInActivePane(
            uri: DocumentURI(fileURL: root.appendingPathComponent("b.txt")), preview: true)
        let activeID = try #require(workspace.activePaneID)
        let pane = try #require(workspace.panes[activeID])
        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0].documentURI.fileURL?.lastPathComponent == "b.txt")
    }

    @Test func workspaceEditCreatesFileAndEditsOpenDoc() async throws {
        let root = try makeTempRoot(files: ["x.txt": "old"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let uri = DocumentURI(fileURL: root.appendingPathComponent("x.txt"))
        let opened = try await workspace.openInActivePane(uri: uri)
        let service = WorkspaceEditService(workspace: workspace)
        let edit = WorkspaceEdit(
            documentChanges: [
                DocumentChange(
                    uri: uri,
                    documentID: opened.document.id,
                    expectedVersion: opened.document.version,
                    transaction: .single(
                        range: NSRange(location: 0, length: 3),
                        replacement: "new",
                        origin: .programmatic
                    )
                )
            ],
            fileOperations: [
                .createFile(uri: DocumentURI(fileURL: root.appendingPathComponent("y.txt")), contents: "yy")
            ]
        )
        let result = try await service.apply(edit)
        #expect(opened.document.text == "new")
        #expect(result.completedFileOperations.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("y.txt").path))
    }

    @Test func renameUpdatesOpenDocumentURI() async throws {
        let root = try makeTempRoot(files: ["old.txt": "body"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let from = DocumentURI(fileURL: root.appendingPathComponent("old.txt"))
        let to = DocumentURI(fileURL: root.appendingPathComponent("new.txt"))
        let opened = try await workspace.openInActivePane(uri: from)
        let service = WorkspaceEditService(workspace: workspace)
        _ = try await service.apply(
            WorkspaceEdit(fileOperations: [.rename(from: from, to: to)])
        )
        #expect(opened.document.uri == to)
        #expect(workspace.documents.document(uri: to)?.id == opened.document.id)
    }

    @Test func restorationRoundTrip() async throws {
        let root = try makeTempRoot(files: ["r.txt": "restore-me"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await Workspace.local(rootDirectories: [root])
        let uri = DocumentURI(fileURL: root.appendingPathComponent("r.txt"))
        let opened = try await workspace.openInActivePane(uri: uri)
        opened.session.selections = [CodeEditorCore.TextRange(location: 2, length: 0)]
        let data = try WorkspaceRestoration.encode(workspace)

        let fs = try LocalWorkspaceFileSystem(rootDirectories: [root])
        let state = try WorkspaceRestoration.decode(data)
        let restored = try await Workspace.restore(from: state, fileSystem: fs)
        #expect(restored.panes.count >= 1)
        let pane = try #require(restored.panes.values.first)
        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0].documentURI == uri)
    }
}

// MARK: - Helpers

private func makeTempRoot(files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CEWorkspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (relative, contents) in files {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: url)
    }
    return dir
}
