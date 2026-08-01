import Foundation
import Testing
@testable import CodeEditorLSP
import CodeEditorDocuments
import CodeEditorCore

@Suite("LSP cross-file snapshots (LSP-003)")
struct CrossFileSnapshotTests {
    @Test func diskSnapshotResolvesTargetURIText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("other.swift")
        try "func target() {}\n".write(to: file, atomically: true, encoding: .utf8)
        let uri = DocumentURI(fileURL: file)
        let resolver = DefaultWorkspaceSnapshotResolver()
        let snap = try await resolver.snapshot(for: uri)
        #expect(snap.text.contains("func target"))
        let range = LSPConvert.textRange(
            LSPRange(start: LSPPosition(line: 0, character: 5), end: LSPPosition(line: 0, character: 11)),
            in: snap.text
        )
        #expect(range.location == 5)
        #expect(range.length == 6)
    }

    @Test func emptyStringDoesNotProduceFakeOffsets() {
        // Empty target text must not invent non-zero locations from line/col alone.
        let range = LSPConvert.textRange(
            LSPRange(start: LSPPosition(line: 10, character: 20), end: LSPPosition(line: 10, character: 25)),
            in: ""
        )
        #expect(range.location == 0)
    }
}
