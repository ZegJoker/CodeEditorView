import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
@testable import CodeEditorSearch

@Suite("Search")
struct SearchTests {
    @Test func findsLiteralAndRegex() async throws {
        let uri = DocumentURI(rawValue: "inmemory:a.swift")
        let ctx = WorkspaceSearchContext(
            openDocuments: [uri: "func hello()\nlet x = hello\n"]
        )
        let service = WorkspaceSearchService(context: ctx)
        var matches: [SearchMatch] = []
        for try await event in await service.search(SearchQuery(pattern: "hello")) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.fromOpenDocument })

        matches = []
        for try await event in await service.search(SearchQuery(pattern: "hel+o", isRegex: true)) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 2)
    }

    @Test func wholeWordAndCase() async throws {
        let uri = DocumentURI(rawValue: "inmemory:b")
        let ctx = WorkspaceSearchContext(openDocuments: [uri: "cat catalog Cat"])
        let service = WorkspaceSearchService(context: ctx)

        var matches: [SearchMatch] = []
        for try await event in await service.search(SearchQuery(pattern: "cat", caseSensitive: true, wholeWord: true)) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 1)

        matches = []
        for try await event in await service.search(SearchQuery(pattern: "Cat", caseSensitive: true)) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 1)
    }

    @Test func excludesGitPaths() {
        #expect(SearchPathMatching.isExcluded(path: "/proj/.git/config", excludes: SearchQuery.defaultExcludes))
        #expect(SearchPathMatching.isExcluded(path: "/proj/.build/debug/x", excludes: SearchQuery.defaultExcludes))
        #expect(!SearchPathMatching.isExcluded(path: "/proj/Sources/A.swift", excludes: SearchQuery.defaultExcludes))
    }

    @Test func binaryDetection() {
        #expect(SearchPathMatching.isBinary(Data([0x00, 0x01, 0x02])))
        #expect(!SearchPathMatching.isBinary(Data("hello world".utf8)))
    }

    @Test func replaceBuildsHighToLowWorkspaceEdit() throws {
        let uri = DocumentURI(rawValue: "inmemory:r")
        let text = "aa aa"
        // two matches at 0 and 3
        let m1 = SearchMatch(
            uri: uri,
            range: CodeEditorCore.TextRange(location: 0, length: 2),
            line: 0, column: 0, preview: "aa aa", fromOpenDocument: true
        )
        let m2 = SearchMatch(
            uri: uri,
            range: CodeEditorCore.TextRange(location: 3, length: 2),
            line: 0, column: 3, preview: "aa aa", fromOpenDocument: true
        )
        let plan = SearchReplacePlan(
            query: SearchQuery(pattern: "aa"),
            replacement: "bb",
            matches: [m1, m2]
        )
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            openDocumentVersions: [uri: DocumentVersion(rawValue: 1)]
        )
        #expect(edit.documentChanges.count == 1)
        let changes = edit.documentChanges[0].transaction.changes
        #expect(changes.count == 2)
        #expect(changes[0].replacedRange.location >= changes[1].replacedRange.location)
        _ = text
    }

    @Test func diskSearchFindsFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "uniqueTokenXYZ".data(using: .utf8)!.write(to: root.appendingPathComponent("f.txt"))

        let service = WorkspaceSearchService(context: WorkspaceSearchContext(rootDirectories: [root]))
        var matches: [SearchMatch] = []
        for try await event in await service.search(SearchQuery(pattern: "uniqueTokenXYZ")) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 1)
        #expect(matches[0].fromOpenDocument == false)
    }
}
