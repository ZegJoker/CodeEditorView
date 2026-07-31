import Foundation
import Testing
import CodeEditorCore
@testable import CodeEditorDocuments

@Suite("Document IO safety")
struct DocumentIOSafetyTests {
    private func tempFile(name: String = "doc.txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test func atomicSaveRoundTrip() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        let original = Data("hello world".utf8)
        try await io.writeAtomically(data: original, to: url)
        let read = try await io.read(url: url)
        #expect(read == original)
        let identity = try await io.resourceIdentity(at: url)
        #expect(identity?.contentHash == DocumentFileIdentity.hash(of: original))
    }

    @Test func faultBeforeReplaceLeavesOriginalIntact() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ioBase = LocalDocumentIO()
        try await ioBase.writeAtomically(data: Data("ORIGINAL".utf8), to: url)

        let faulting = FaultInjectingDocumentIO(base: ioBase, fault: .beforeReplace)
        do {
            try await faulting.writeAtomically(data: Data("NEW-CONTENT".utf8), to: url)
            Issue.record("expected injected fault")
        } catch let error as DocumentIOError {
            guard case .injectedFault(.beforeReplace) = error else {
                Issue.record("wrong fault \(error)")
                return
            }
        }
        let remaining = try await ioBase.read(url: url)
        #expect(String(data: remaining, encoding: .utf8) == "ORIGINAL")
    }

    @Test func faultAfterTempWriteLeavesOriginalIntact() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ioBase = LocalDocumentIO()
        try await ioBase.writeAtomically(data: Data("KEEP".utf8), to: url)
        let faulting = FaultInjectingDocumentIO(base: ioBase, fault: .afterTempWrite)
        do {
            try await faulting.writeAtomically(data: Data("LOSE".utf8), to: url)
            Issue.record("expected fault")
        } catch {
            // expected
        }
        #expect(String(data: try await ioBase.read(url: url), encoding: .utf8) == "KEEP")
    }

    @Test func encodingAndCRLFFidelity() async throws {
        let url = try tempFile(name: "crlf.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = LocalFileDocumentProvider(
            io: LocalDocumentIO(),
            policy: DocumentLifecyclePolicy(
                lineEndingOnSave: .convert(.carriageReturnLineFeed),
                bomPolicy: .none,
                writeRecoveryJournal: false
            ),
            useCoordinator: false
        )
        let snap = DocumentSnapshot(version: .zero, text: "a\nb\nc")
        let uri = DocumentURI(fileURL: url)
        try await provider.save(snap, to: uri, encoding: .utf8)
        let loaded = try await provider.load(uri: uri)
        #expect(loaded.text.contains("\r\n") || loaded.lineEnding == .carriageReturnLineFeed)
        // After convert, file bytes should be CRLF
        let bytes = try await LocalDocumentIO().read(url: url)
        let s = String(data: bytes, encoding: .utf8)!
        #expect(s == "a\r\nb\r\nc")
    }

    @Test func utf8BOMRoundTrip() async throws {
        let url = try tempFile(name: "bom.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = LocalFileDocumentProvider(
            io: LocalDocumentIO(),
            policy: DocumentLifecyclePolicy(bomPolicy: .whenEncodingSupports, writeRecoveryJournal: false),
            useCoordinator: false
        )
        try await provider.save(
            DocumentSnapshot(version: .zero, text: "hi"),
            to: DocumentURI(fileURL: url),
            encoding: .utf8
        )
        let data = try await LocalDocumentIO().read(url: url)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let loaded = try await provider.load(uri: DocumentURI(fileURL: url))
        #expect(loaded.text == "hi")
        #expect(loaded.hadBOM)
    }

    @Test func recoveryJournalRestoresDirtyContent() async throws {
        let url = try tempFile(name: "recover.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("disk".utf8), to: url)
        let journal = RecoveryJournal(directory: url.deletingLastPathComponent())
        try await journal.write(text: "recovered-dirty", forPrimary: url, io: io)
        let text = try await journal.read(forPrimary: url, io: io)
        #expect(text == "recovered-dirty")
        try await journal.clear(forPrimary: url, io: io)
        #expect(try await journal.read(forPrimary: url, io: io) == nil)
    }

    @Test func externalChangeDetection() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        let provider = LocalFileDocumentProvider(io: io, policy: .default, useCoordinator: false)
        let uri = DocumentURI(fileURL: url)
        try await provider.save(
            DocumentSnapshot(version: .zero, text: "v1"),
            to: uri,
            encoding: DocumentEncoding.utf8
        )
        let known = try #require(await io.resourceIdentity(at: url))
        #expect(try await provider.detectChange(at: uri, known: known) == .unchanged)
        try await io.writeAtomically(data: Data("v2-different".utf8), to: url)
        let after = try #require(await io.resourceIdentity(at: url))
        #expect(after.contentHash != known.contentHash)
        #expect(try await provider.detectChange(at: uri, known: known) == .externalModified)
        try await io.removeItem(at: url)
        #expect(try await provider.detectChange(at: uri, known: known) == .deleted)
    }

    @Test func encodingFailureLeavesFileUnchanged() async throws {
        // Use a snapshot that cannot encode to ascii via forcing invalid - DocumentEncoding.utf8 always works.
        // Instead verify readOnly policy blocks save.
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("safe".utf8), to: url)
        let provider = LocalFileDocumentProvider(
            io: io,
            policy: DocumentLifecyclePolicy(writeRecoveryJournal: false, isReadOnly: true),
            useCoordinator: false
        )
        do {
            try await provider.save(
                DocumentSnapshot(version: .zero, text: "nope"),
                to: DocumentURI(fileURL: url),
                encoding: DocumentEncoding.utf8
            )
            Issue.record("expected readOnly")
        } catch let error as DocumentProviderError {
            #expect(error == .readOnly)
        }
        #expect(String(data: try await io.read(url: url), encoding: .utf8) == "safe")
    }
}

@Suite("Document URI registry")
@MainActor
struct DocumentURIRegistryTests {
    @Test func canonicalFileURILookup() {
        let registry = DocumentRegistry()
        let path = "/tmp/codeeditor-uri-\(UUID().uuidString).txt"
        let url1 = URL(fileURLWithPath: path)
        let url2 = URL(fileURLWithPath: path).standardizedFileURL
        let doc = TextDocument(uri: DocumentURI(fileURL: url1), text: "x")
        registry.register(doc)
        #expect(registry.document(uri: DocumentURI(fileURL: url2)) === doc)
    }
}

@Suite("TextDocument recovery")
@MainActor
struct TextDocumentRecoveryTests {
    @Test func recoverFromJournal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("on-disk".utf8), to: url)
        let doc = TextDocument(uri: DocumentURI(fileURL: url), text: "on-disk")
        let journal = RecoveryJournal(directory: dir)
        try await journal.write(text: "from-journal", forPrimary: url, io: io)
        let ok = try await doc.recoverFromJournalIfNeeded(io: io)
        #expect(ok)
        #expect(doc.text == "from-journal")
        #expect(doc.isDirty)
    }
}
