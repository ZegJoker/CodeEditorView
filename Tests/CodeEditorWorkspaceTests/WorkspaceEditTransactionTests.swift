import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorWorkspace

@Suite("WorkspaceEdit transactions")
@MainActor
struct WorkspaceEditTransactionTests {
    private func makeWorkspace() async throws -> (Workspace, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("we-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let ws = Workspace(fileSystem: fs, documentProvider: InMemoryDocumentProvider())
        return (ws, root)
    }

    @Test func staleVersionAbortsWithNoMutation() async throws {
        let (ws, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = TextDocument(text: "hello")
        ws.documents.register(doc)
        let bad = WorkspaceEdit(documentChanges: [
            DocumentChange(
                uri: doc.uri,
                documentID: doc.id,
                expectedVersion: DocumentVersion(rawValue: 99),
                transaction: .single(range: NSRange(location: 0, length: 0), replacement: "x")
            )
        ])
        let service = WorkspaceEditService(workspace: ws)
        do {
            _ = try await service.apply(bad)
            Issue.record("expected version mismatch")
        } catch let error as WorkspaceEditError {
            guard case .versionMismatch = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        #expect(doc.text == "hello")
        #expect(doc.version == .zero)
    }

    @Test func faultAfterFirstDocumentRollsBack() async throws {
        let (ws, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = TextDocument(text: "aaa")
        let b = TextDocument(text: "bbb")
        ws.documents.register(a)
        ws.documents.register(b)
        let edit = WorkspaceEdit(documentChanges: [
            DocumentChange(
                uri: a.uri,
                documentID: a.id,
                expectedVersion: a.version,
                transaction: .single(range: NSRange(location: 0, length: 3), replacement: "AAA")
            ),
            DocumentChange(
                uri: b.uri,
                documentID: b.id,
                expectedVersion: b.version,
                transaction: .single(range: NSRange(location: 0, length: 3), replacement: "BBB")
            ),
        ])
        let service = WorkspaceEditService(workspace: ws)
        service.faultPoint = .afterFirstDocument
        do {
            _ = try await service.apply(edit)
            Issue.record("expected fault")
        } catch {
            // expected
        }
        #expect(a.text == "aaa")
        #expect(b.text == "bbb")
    }

    @Test func successfulCreateFileInverse() async throws {
        let (ws, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("n.txt")
        let uri = DocumentURI(fileURL: fileURL)
        let edit = WorkspaceEdit(fileOperations: [
            .createFile(uri: uri, contents: "hi")
        ])
        let service = WorkspaceEditService(workspace: ws)
        let result = try await service.apply(edit)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!result.inverse.fileOperations.isEmpty)
    }

    @Test func pathEscapeRejected() throws {
        #expect(throws: WorkspaceFileSystemError.self) {
            try WorkspacePathSecurity.validateRelativePath("../etc/passwd")
        }
        let root = URL(fileURLWithPath: "/tmp")
        #expect(throws: WorkspaceFileSystemError.self) {
            try WorkspacePathSecurity.resolveUnderRoot(root: root, relativePath: "../../etc")
        }
    }

    @Test func snapshotCapturesVersions() async throws {
        let (ws, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = TextDocument(text: "x")
        ws.documents.register(doc)
        _ = try doc.apply(.single(range: NSRange(location: 1, length: 0), replacement: "y"))
        let snap = await ws.snapshot()
        #expect(snap.documentVersions[doc.uri] == doc.version)
        #expect(snap.openDocumentIDs.contains(doc.id))
    }
}
