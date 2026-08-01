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
        try await provider.save(
            DocumentSnapshot(version: .zero, text: "world"),
            to: uri,
            encoding: .utf8
        )
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
        let provider = LocalFileDocumentProvider()
        try await provider.save(
            DocumentSnapshot(version: .zero, text: "file-body\n"),
            to: uri,
            encoding: .utf8
        )
        let loaded = try await provider.load(uri: uri)
        #expect(loaded.text == "file-body\n")
        #expect(loaded.encoding == .utf8)
    }
}
