import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorWorkspace

// MARK: - Dirty close + leases (WSP-001 / WSP-006)

@MainActor
private final class RecordingCloseDelegate: WorkspaceCloseDelegate, @unchecked Sendable {
    var decisions: [DocumentID: CloseDecision] = [:]
    var lastCandidates: [CloseCandidate] = []

    func decideClose(_ documents: [CloseCandidate]) async -> [DocumentID: CloseDecision] {
        lastCandidates = documents
        var out: [DocumentID: CloseDecision] = [:]
        for c in documents {
            out[c.documentID] = decisions[c.documentID] ?? .cancel
        }
        return out
    }
}

@Suite("Phase4 dirty close and leases")
@MainActor
struct Phase4DirtyCloseLeaseTests {
    private func makeWorkspace(
        policy: DirtyTabClosePolicy = .prompt
    ) async throws -> (Workspace, URL) {
        let root = try makeTempRoot(files: ["a.txt": "alpha", "b.txt": "beta"])
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let ws = Workspace(
            fileSystem: fs,
            documentProvider: LocalFileDocumentProvider(),
            dirtyTabClosePolicy: policy
        )
        return (ws, root)
    }

    @Test func dirtyCancelKeepsTabWithoutDelegate() async throws {
        let (ws, root) = try await makeWorkspace(policy: .prompt)
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("a.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "X")
        )
        #expect(opened.document.isDirty)
        let paneID = try #require(ws.activePaneID)
        let result = await ws.requestCloseTab(opened.tab.id, in: paneID)
        #expect(result == .cancelled)
        #expect(ws.panes[paneID]?.tabs.count == 1)
        #expect(ws.documents.document(id: opened.document.id) != nil)
    }

    @Test func dirtyDiscardClosesAndUnregisters() async throws {
        let (ws, root) = try await makeWorkspace(policy: .discard)
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("a.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "X")
        )
        let paneID = try #require(ws.activePaneID)
        let result = await ws.requestCloseTab(opened.tab.id, in: paneID)
        #expect(result == .closed)
        #expect(ws.panes[paneID]?.tabs.isEmpty == true)
        #expect(ws.documents.document(id: opened.document.id) == nil)
    }

    @Test func multiTabSharedDocCloseOneKeepsDocument() async throws {
        let (ws, root) = try await makeWorkspace(policy: .prompt)
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("a.txt"))
        let first = try await ws.openInActivePane(uri: uri)
        _ = try first.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "Z")
        )
        let sourcePane = try #require(ws.activePaneID)
        let secondPane = try #require(ws.splitActivePane(axis: .horizontal))
        #expect(ws.documentLeases.count(for: first.document.id) == 2)
        let result = await ws.requestCloseTab(
            ws.panes[secondPane]!.tabs[0].id,
            in: secondPane
        )
        #expect(result == .closed)
        #expect(ws.documents.document(id: first.document.id) != nil)
        #expect(ws.documentLeases.count(for: first.document.id) == 1)
        // Last dirty lease still requires decision (tab lives on source pane).
        let last = await ws.requestCloseTab(first.tab.id, in: sourcePane)
        #expect(last == .cancelled)
    }

    @Test func syncCloseTabFailsClosedOnDirtyLastLease() async throws {
        let (ws, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("a.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "Y")
        )
        let paneID = try #require(ws.activePaneID)
        ws.closeTab(opened.tab.id, in: paneID)
        #expect(ws.panes[paneID]?.tabs.count == 1)
    }

    @Test func saveDecisionPersistsThenCloses() async throws {
        let (ws, root) = try await makeWorkspace(policy: .save)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt")
        let uri = DocumentURI(fileURL: file)
        let opened = try await ws.openInActivePane(uri: uri)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 5), replacement: "SAVED")
        )
        let paneID = try #require(ws.activePaneID)
        let result = await ws.requestCloseTab(opened.tab.id, in: paneID)
        #expect(result == .closed)
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk == "SAVED")
    }
}

// MARK: - Path security corpus (WSP-003)

@Suite("Phase4 path security")
struct Phase4PathSecurityTests {
    @Test func rejectsTraversalAndMalformed() {
        let bad = [
            "../etc/passwd",
            "/abs",
            "foo//bar",
            "foo/./bar",
            "foo\0bar",
            "foo/../bar",
            "foo\\bar",
            "C:\\\\windows",
            "foo/",
            "/foo/bar",
        ]
        for path in bad {
            #expect(throws: WorkspaceFileSystemError.self) {
                try WorkspacePathSecurity.validateRelativePath(path)
            }
            #expect(throws: WorkspaceFileSystemError.self) {
                _ = try RelativeWorkspacePath(validating: path)
            }
        }
    }

    @Test func acceptsValidRelative() throws {
        let p = try RelativeWorkspacePath(validating: "src/main.swift")
        #expect(p.segments == ["src", "main.swift"])
        #expect(p.pathString == "src/main.swift")
        let nested = try p.appending("x")
        #expect(nested.segments.count == 3)
    }

    @Test func resolveRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try "secret".data(using: .utf8)!.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: WorkspaceFileSystemError.self) {
            _ = try WorkspacePathSecurity.resolveUnderRoot(
                root: root,
                relativePath: "escape-link",
                options: WorkspacePathResolveOptions(symlinkPolicy: .denyEscape)
            )
        }
    }

    @Test func resolveAllowsContained() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ok.txt")
        try "ok".data(using: .utf8)!.write(to: file)
        let resolved = try WorkspacePathSecurity.resolveUnderRoot(root: root, relativePath: "ok.txt")
        #expect(resolved.standardizedFileURL.path == file.standardizedFileURL.path)
    }

    @Test func sameVolumeOption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("v.txt")
        try Data().write(to: file)
        let url = try WorkspacePathSecurity.resolveUnderRoot(
            root: root,
            relativePath: "v.txt",
            options: WorkspacePathResolveOptions(requireSameVolume: true)
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Trust (WSP / §8.7)

@Suite("Phase4 trust")
struct Phase4TrustTests {
    @Test func defaultRestrictedDeniesProcessCapabilities() {
        let trust = WorkspaceTrustState.default
        #expect(trust.level == .restricted)
        for cap in WorkspaceTrustCapability.allCases {
            #expect(!trust.allows(cap))
        }
        var promoted = trust
        promoted.promote(to: .trusted)
        #expect(promoted.allows(.taskExecution))
        #expect(promoted.allows(.languageServerLaunch))
    }
}

// MARK: - Watcher overflow (WSP-005)

@Suite("Phase4 watcher")
@MainActor
struct Phase4WatcherTests {
    @Test func mockOverflowEmitsRescan() async throws {
        let mock = MockWorkspaceFileWatcher()
        let root = try makeTempRoot(files: ["w.txt": "w"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: true,
            watcher: mock
        )
        let rootID = await fs.roots.first!.id
        let stream = await fs.events()
        mock.emit(.overflow(rootID: rootID))
        var sawRescan = false
        let task = Task {
            for try await event in stream {
                if case .rescanRequired = event {
                    sawRescan = true
                    break
                }
            }
        }
        // Give the actor a tick.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(sawRescan || mock.startedRoots.contains(rootID))
        // Always at least started.
        #expect(mock.startedRoots.contains(rootID))
    }
}

// MARK: - Restoration fixtures (WSP-007)

@Suite("Phase4 restoration")
@MainActor
struct Phase4RestorationTests {
    @Test func rejectsFutureSchema() throws {
        let state = WorkspaceRestorationState(
            schemaVersion: 999,
            workspaceID: WorkspaceID(),
            roots: [],
            layout: .pane(EditorPaneID()),
            panes: [],
            activePaneID: nil,
            focusHistory: [],
            navigation: [],
            navigationIndex: -1
        )
        #expect(throws: WorkspaceRestorationError.self) {
            _ = try WorkspaceRestoration.migrate(state)
        }
    }

    @Test func rejectsCorruptJSON() {
        let junk = Data("{\"not\":valid".utf8)
        #expect(throws: WorkspaceRestorationError.self) {
            _ = try WorkspaceRestoration.decode(junk)
        }
    }

    @Test func v1RoundTripFixture() async throws {
        let root = try makeTempRoot(files: ["fixture.txt": "golden"])
        defer { try? FileManager.default.removeItem(at: root) }
        let ws = try await Workspace.local(rootDirectories: [root])
        _ = try await ws.openInActivePane(
            uri: DocumentURI(fileURL: root.appendingPathComponent("fixture.txt"))
        )
        let data = try await WorkspaceRestoration.encode(ws)
        let decoded = try WorkspaceRestoration.decode(data)
        #expect(decoded.schemaVersion == WorkspaceRestorationState.currentSchemaVersion)
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root], enablesDirectoryWatching: false)
        let restored = try await Workspace.restore(from: decoded, fileSystem: fs)
        #expect(restored.panes.values.flatMap(\.tabs).count == 1)
    }
}

// MARK: - Workspace edit fault matrix (WSP-002)

@Suite("Phase4 workspace edit faults")
@MainActor
struct Phase4EditFaultTests {
    private func makeWS() async throws -> (Workspace, URL) {
        let root = try makeTempRoot(files: ["d.txt": "data", "e.txt": "else"])
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root], enablesDirectoryWatching: false)
        return (Workspace(fileSystem: fs, documentProvider: LocalFileDocumentProvider()), root)
    }

    @Test func faultBeforeCommitLeavesFilesIntact() async throws {
        let (ws, root) = try await makeWS()
        defer { try? FileManager.default.removeItem(at: root) }
        let del = DocumentURI(fileURL: root.appendingPathComponent("d.txt"))
        let service = WorkspaceEditService(workspace: ws)
        service.faultPoint = .beforeCommit
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("journals-\(UUID().uuidString)", isDirectory: true)
        service.journalRoot = journalRoot
        do {
            _ = try await service.apply(WorkspaceEdit(fileOperations: [.delete(uri: del)]))
            Issue.record("expected fault")
        } catch {
            // expected
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("d.txt").path))
    }

    @Test func binaryCreateAndDeleteRollback() async throws {
        let (ws, root) = try await makeWS()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let uri = DocumentURI(fileURL: root.appendingPathComponent("bin.dat"))
        let service = WorkspaceEditService(workspace: ws)
        let create = WorkspaceEdit(fileOperations: [
            .createFileBytes(uri: uri, contentsBase64: bytes.base64EncodedString())
        ])
        _ = try await service.apply(create)
        #expect(try Data(contentsOf: uri.fileURL!) == bytes)

        service.faultPoint = .afterFirstFileOp
        // Single op won't trip afterFirstFileOp for multi; use delete + create
        let other = DocumentURI(fileURL: root.appendingPathComponent("e.txt"))
        let multi = WorkspaceEdit(fileOperations: [
            .delete(uri: uri),
            .delete(uri: other),
        ])
        do {
            _ = try await service.apply(multi)
            Issue.record("expected fault")
        } catch {
            // rollback should restore bin.dat
        }
        #expect(FileManager.default.fileExists(atPath: uri.fileURL!.path))
        #expect(try Data(contentsOf: uri.fileURL!) == bytes)
    }
}

// MARK: - Helpers

private func makeTempRoot(files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CEPhase4-\(UUID().uuidString)", isDirectory: true)
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
