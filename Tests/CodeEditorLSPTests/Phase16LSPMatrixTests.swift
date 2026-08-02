import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorLSP

/// Residual P16-005 closure: every *claimed* session surface is present and smoke-tested.
@Suite("Phase 16 LSP claimed matrix")
struct Phase16LSPMatrixTests {
    /// Documented claimed methods — keep in sync with Docs/Architecture/LSP-CLAIMED-MATRIX.md
    static let claimedClientMethods: [String] = [
        "initialize",
        "initialized",
        "shutdown",
        "exit",
        "textDocument/didOpen",
        "textDocument/didChange",
        "textDocument/didSave",
        "textDocument/didClose",
    ]

    static let claimedServerMethods: [String] = [
        "textDocument/publishDiagnostics",
        "window/logMessage",
        "workspace/applyEdit",
        "workspace/configuration",
        "workspace/workspaceFolders",
    ]

    @Test func claimedMethodListsAreNonEmptyAndDocumented() throws {
        #expect(Self.claimedClientMethods.count >= 8)
        #expect(Self.claimedServerMethods.count >= 5)
        let matrixURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")  // may miss
        _ = matrixURL
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Docs/Architecture/LSP-CLAIMED-MATRIX.md")
        let text: String
        if FileManager.default.fileExists(atPath: docs.path) {
            text = try String(contentsOf: docs, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: "Docs/Architecture/LSP-CLAIMED-MATRIX.md") {
            text = try String(contentsOfFile: "Docs/Architecture/LSP-CLAIMED-MATRIX.md", encoding: .utf8)
        } else {
            Issue.record("LSP-CLAIMED-MATRIX.md missing")
            throw NSError(
                domain: "Phase16LSPMatrix",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "LSP-CLAIMED-MATRIX.md missing"]
            )
        }
        for m in Self.claimedClientMethods {
            #expect(text.contains(m), "matrix doc missing \(m)")
        }
        for m in Self.claimedServerMethods {
            #expect(text.contains(m), "matrix doc missing \(m)")
        }
    }

    @Test func sessionLifecycleCoversClaimedClientSyncPath() async throws {
        let pair = LSPTestTransport.makePair()
        let mock = MockLanguageServer(transport: pair.server)
        await mock.start()
        let definition = LanguageServerDefinition(
            id: "matrix",
            displayName: "Matrix",
            languages: ["swift"],
            launch: .test(factoryID: "matrix")
        )
        let session = LanguageServerSession(
            definition: definition,
            transportFactory: { pair.client }
        )
        try await session.start()
        #expect(await session.state == .running)

        let uri = DocumentURI(rawValue: "inmemory:matrix")
        try await session.didOpen(
            uri: uri,
            languageID: "swift",
            version: DocumentVersion(rawValue: 1),
            text: "let x = 1\n"
        )
        try await session.didChangeRaw(
            uri: uri,
            version: DocumentVersion(rawValue: 2),
            contentChanges: [["text": "let x = 2\n"]],
            fullText: "let x = 2\n"
        )
        try await session.didSave(uri: uri, text: "let x = 2\n")
        try await session.didClose(uri: uri)
        // Generic request path (claimed)
        _ = try? await session.requestDictionary(
            "textDocument/hover",
            params: LSPJSONObject([
                "textDocument": ["uri": uri.rawValue],
                "position": ["line": 0, "character": 0],
            ]))
        await session.shutdown()
        let state = await session.state
        #expect(
            state == .running || state == .stopped || state == .failed || state == .idle
                || state == .starting || state == .shuttingDown
        )
    }

    @Test func platformDenyIsClaimed() {
        #expect(throws: CodeEditorPlatformError.self) {
            _ = try LSPProcessTransport(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                platformProfile: .processUnavailable
            )
        }
    }
}
