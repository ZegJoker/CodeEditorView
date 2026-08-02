import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorDocuments

@Suite("TextDocument")
@MainActor
struct TextDocumentTests {
    @Test func applyBumpsVersionAndMarksDirty() throws {
        let doc = TextDocument(text: "hi")
        #expect(doc.version == .zero)
        #expect(doc.isDirty == false)
        let applied = try doc.apply(
            .single(range: NSRange(location: 2, length: 0), replacement: "!", origin: .typing)
        )
        #expect(doc.text == "hi!")
        #expect(doc.version == DocumentVersion(rawValue: 1))
        #expect(doc.isDirty)
        #expect(applied.oldVersion == .zero)
        #expect(applied.newVersion == doc.version)
        #expect(applied.beforeState != applied.afterState)
    }

    @Test func undoRedoRoundTrip() throws {
        let doc = TextDocument(text: "a")
        _ = try doc.apply(
            .single(range: NSRange(location: 1, length: 0), replacement: "b", origin: .typing)
        )
        #expect(doc.text == "ab")
        let afterInsert = doc.version
        try doc.performUndo()
        #expect(doc.text == "a")
        #expect(doc.version > afterInsert)
        try doc.performRedo()
        #expect(doc.text == "ab")
    }

    @Test func markCleanAndExternalReloadIfClean() throws {
        let doc = TextDocument(text: "old")
        _ = try doc.apply(
            .single(range: NSRange(location: 0, length: 3), replacement: "x", origin: .typing)
        )
        #expect(doc.isDirty)
        #expect(try doc.applyExternalContent("external", policy: .reloadIfClean) == false)
        doc.markClean()
        #expect(try doc.applyExternalContent("external", policy: .reloadIfClean))
        #expect(doc.text == "external")
        #expect(!doc.isDirty)
    }

    @Test func alwaysReloadExternal() throws {
        let doc = TextDocument(text: "dirty")
        _ = try doc.apply(
            .single(range: NSRange(location: 0, length: 1), replacement: "D", origin: .typing)
        )
        #expect(try doc.applyExternalContent("fresh", policy: .alwaysReload))
        #expect(doc.text == "fresh")
        #expect(!doc.isDirty)
    }

    // MARK: - DOC-N01 content-state savepoints

    @Test func test_DOC_N01_undoToSavepointIsClean() throws {
        let doc = TextDocument(text: "hello")
        #expect(!doc.isDirty)
        let cleanState = doc.contentState
        _ = try doc.apply(
            .single(range: NSRange(location: 5, length: 0), replacement: "!", origin: .typing)
        )
        #expect(doc.isDirty)
        #expect(doc.contentState != cleanState)
        try doc.performUndo()
        #expect(doc.text == "hello")
        #expect(doc.contentState == cleanState)
        #expect(!doc.isDirty)
    }

    @Test func test_DOC_N01_redoBecomesDirty() throws {
        let doc = TextDocument(text: "hello")
        _ = try doc.apply(
            .single(range: NSRange(location: 5, length: 0), replacement: "!", origin: .typing)
        )
        try doc.performUndo()
        #expect(!doc.isDirty)
        try doc.performRedo()
        #expect(doc.text == "hello!")
        #expect(doc.isDirty)
    }

    @Test func test_DOC_N01_saveAfterUndoMovesSavepoint() throws {
        let doc = TextDocument(text: "a")
        _ = try doc.apply(
            .single(range: NSRange(location: 1, length: 0), replacement: "b", origin: .typing)
        )
        try doc.performUndo()
        #expect(!doc.isDirty)
        // Edit again, undo to original, then markClean as if save succeeded after undo.
        _ = try doc.apply(
            .single(range: NSRange(location: 1, length: 0), replacement: "c", origin: .typing)
        )
        #expect(doc.isDirty)
        try doc.performUndo()
        #expect(!doc.isDirty)
        doc.markClean()
        #expect(doc.savepoint?.contentState == doc.contentState)
        #expect(!doc.isDirty)
    }

    @Test func test_DOC_N01_monotonicVersionsShareContentState() throws {
        let doc = TextDocument(text: "x")
        let v0 = doc.version
        let s0 = doc.contentState
        _ = try doc.apply(
            .single(range: NSRange(location: 1, length: 0), replacement: "y", origin: .typing)
        )
        let s1 = doc.contentState
        try doc.performUndo()
        #expect(doc.contentState == s0)
        #expect(doc.version > v0)
        // Version advanced through undo even though content state restored.
        #expect(doc.version.rawValue >= 2)
        try doc.performRedo()
        #expect(doc.contentState == s1)
        #expect(doc.version > v0)
    }

    @Test func test_DOC_N01_externalReloadEstablishesCleanState() throws {
        let doc = TextDocument(text: "old")
        _ = try doc.apply(
            .single(range: NSRange(location: 0, length: 3), replacement: "x", origin: .typing)
        )
        #expect(doc.isDirty)
        #expect(try doc.applyExternalContent("external", policy: .alwaysReload))
        #expect(!doc.isDirty)
        #expect(doc.savepoint?.contentState == doc.contentState)
    }

    @Test func test_DOC_N01_failedSaveDoesNotBecomeClean() async throws {
        let doc = TextDocument(text: "local")
        _ = try doc.apply(
            .single(range: NSRange(location: 5, length: 0), replacement: "!", origin: .typing)
        )
        #expect(doc.isDirty)
        let provider = InMemoryDocumentProvider()
        // In-memory without overwrite + with expected identity → unsupported, not clean.
        doc.setFileIdentity(
            DocumentFileIdentity(contentHash: "deadbeef", size: 1)
        )
        let outcome = try await doc.save(
            using: provider,
            conflictPolicy: .requireHostDecision
        )
        #expect(outcome == .unsupportedConflictDetection)
        #expect(doc.isDirty)
    }

    // MARK: - DOC-N06 bounded events

    @Test func test_DOC_N06_rejectsUnboundedEventStream() {
        let doc = TextDocument(text: "x")
        #expect(throws: EventBufferPolicyError.self) {
            _ = try doc.makeEventStream(bufferSize: 0)
        }
        #expect(throws: EventBufferPolicyError.self) {
            _ = try doc.makeEventStream(bufferSize: -5)
        }
    }

    @Test func test_DOC_N06_eventsCarrySequence() async throws {
        let doc = TextDocument(text: "a")
        // Tiny buffer so overflow is deterministic without concurrent consumer.
        let policy = try EventBufferPolicy(capacity: 2)
        let stream = doc.makeEventStream(policy: policy)

        // Each apply yields willApply + didApply (+ dirty); flood past capacity.
        for _ in 0..<6 {
            _ = try doc.apply(
                .single(
                    range: NSRange(location: doc.length, length: 0),
                    replacement: "x",
                    origin: .typing
                )
            )
        }
        #expect(doc.eventSequence >= 2)
        #expect(doc.droppedEventCount > 0)

        // Drain the bounded buffer (buffered elements are available immediately).
        var drained: [TextDocumentEvent] = []
        for await event in stream {
            drained.append(event)
            if drained.count >= policy.capacity { break }
        }

        #expect(drained.count == policy.capacity)
        // Every drained event carries a positive sequence (DOC-N06).
        for event in drained {
            #expect(event.sequence > 0)
        }
        // Overflow must publish a streamGap marker so consumers resync.
        let hasGap = drained.contains { event in
            if case .streamGap = event { return true }
            return false
        }
        #expect(hasGap)
        #expect(doc.droppedEventCount >= 1)
    }
}

@Suite("DocumentRegistry")
@MainActor
struct DocumentRegistryTests {
    @Test func registerLookupAndRemove() {
        let registry = DocumentRegistry()
        let doc = TextDocument(text: "x")
        registry.register(doc)
        #expect(registry.document(id: doc.id) === doc)
        #expect(registry.document(uri: doc.uri) === doc)
        _ = registry.remove(id: doc.id)
        #expect(registry.document(id: doc.id) == nil)
    }
}

@Suite("Document providers")
struct DocumentProviderTests {
    @Test func inMemoryRoundTrip() async throws {
        let provider = InMemoryDocumentProvider()
        let uri = DocumentURI(rawValue: "inmemory:test")
        await provider.store(uri: uri, text: "hello", encoding: .utf8)
        let loaded = try await provider.load(uri: uri)
        #expect(loaded.text == "hello")
        let outcome = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "world"),
                target: uri,
                encoding: .utf8,
                expectedIdentity: nil,
                conflictPolicy: .overwrite
            )
        )
        guard case .saved = outcome else {
            Issue.record("expected saved, got \(outcome)")
            return
        }
        let again = try await provider.load(uri: uri)
        #expect(again.text == "world")
    }

    @Test func localFileRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEditorDocumentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sample.txt")
        let uri = DocumentURI(fileURL: file)
        let provider = LocalFileDocumentProvider(useCoordinator: false)
        let outcome = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "file-body\n"),
                target: uri,
                encoding: .utf8,
                expectedIdentity: nil,
                conflictPolicy: .overwrite
            )
        )
        guard case .saved = outcome else {
            Issue.record("expected saved")
            return
        }
        let loaded = try await provider.load(uri: uri)
        #expect(loaded.text == "file-body\n")
        #expect(loaded.encoding == .utf8)
    }

    @Test func test_DOC_N02_inMemoryUnsupportedConflictDetection() async throws {
        let provider = InMemoryDocumentProvider()
        #expect(await provider.supportsConflictDetection == false)
        let uri = DocumentURI(rawValue: "inmemory:cas")
        let outcome = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "x"),
                target: uri,
                encoding: .utf8,
                expectedIdentity: DocumentFileIdentity(contentHash: "abc", size: 1),
                conflictPolicy: .requireHostDecision
            )
        )
        #expect(outcome == .unsupportedConflictDetection)
    }
}
