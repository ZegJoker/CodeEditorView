import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorSearch

@Suite("GitIgnore")
struct GitIgnoreTests {
    @Test func negationAndDirectoryRules() {
        let rules = GitIgnoreRules.parse(
            fileContents: """
                *.log
                !keep.log
                build/
                """)
        #expect(rules.isIgnored(relativePath: "a.log", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "keep.log", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "build", isDirectory: true))
        #expect(!rules.isIgnored(relativePath: "build.txt", isDirectory: false))
    }

    @Test func searchRespectsGitIgnore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "secret".data(using: .utf8)!.write(to: root.appendingPathComponent("hidden.txt"))
        try "visible".data(using: .utf8)!.write(to: root.appendingPathComponent("show.txt"))
        try "hidden.txt\n".data(using: .utf8)!.write(to: root.appendingPathComponent(".gitignore"))

        let ctx = WorkspaceSearchContext(rootDirectories: [root])
        let service = WorkspaceSearchService(
            context: ctx,
            backendOptions: NativeSearchBackend(respectGitIgnore: true)
        )
        var paths: [String] = []
        for try await event in await service.search(SearchQuery(pattern: "s")) {
            if case .match(let m) = event {
                paths.append(m.uri.fileURL?.lastPathComponent ?? "")
            }
        }
        #expect(paths.contains("show.txt"))
        #expect(!paths.contains("hidden.txt"))
    }
}

@Suite("Search DOC-N05 overflow")
struct SearchDOC05OverflowTests {
    /// Untrusted / malformed match ranges must not trap on location+length (DOC-N05).
    @Test func test_DOC_N05_searchReplaceOverflowSafeRangeArithmetic() throws {
        let text = "hello world"
        let overflowMatch = SearchMatch(
            uri: DocumentURI(rawValue: "file:///doc.txt"),
            range: TextRange(location: Int.max - 1, length: 10),
            line: 1,
            column: 1,
            preview: "hello",
            fromOpenDocument: true
        )
        // Must not trap; falls back to preview when range is invalid for the document.
        let replaced = try SearchReplaceBuilder.replacementText(
            for: overflowMatch,
            template: "X",
            query: SearchQuery(pattern: "hello"),
            fullText: text,
            preserveCase: false
        )
        #expect(replaced == "X")

        let overlong = SearchMatch(
            uri: DocumentURI(rawValue: "file:///doc.txt"),
            range: TextRange(location: 0, length: Int.max),
            line: 1,
            column: 1,
            preview: "hello",
            fromOpenDocument: true
        )
        let overlongReplaced = try SearchReplaceBuilder.replacementText(
            for: overlong,
            template: "Y",
            query: SearchQuery(pattern: "hello"),
            fullText: text,
            preserveCase: false
        )
        #expect(overlongReplaced == "Y")
    }
}

@Suite("Search replace stale")
@MainActor
struct SearchReplaceStaleTests {
    @Test func staleOpenDocAbortsReplace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(rootDirectories: [root], enablesDirectoryWatching: false)
        let ws = Workspace(fileSystem: fs)
        let doc = TextDocument(text: "hello hello")
        try await ws.lifecycle.openExisting(doc)

        let matches = [
            SearchMatch(
                uri: doc.uri,
                range: TextRange(location: 0, length: 5),
                line: 1,
                column: 1,
                preview: "hello hello",
                fromOpenDocument: true
            )
        ]
        let plan = SearchReplacePlan(query: SearchQuery(pattern: "hello"), replacement: "hi", matches: matches)

        // Bump version so expectedVersion from builder path mismatches if we freeze versions first.
        var versions = [doc.uri: doc.version]
        _ = try doc.apply(.single(range: NSRange(location: 0, length: 0), replacement: "!"))
        // Rebuild edit with stale expected version.
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            openDocumentVersions: versions,
            documentTexts: [doc.uri: "hello hello"]
        )
        let service = WorkspaceEditService(workspace: ws)
        do {
            _ = try await service.apply(edit)
            Issue.record("expected stale version")
        } catch let error as WorkspaceEditError {
            guard case .versionMismatch = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        // Document was only mutated by the intentional bump, not replace-all.
        #expect(doc.text.hasPrefix("!hello"))
    }
}
