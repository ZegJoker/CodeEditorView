import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Testing

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
        for try await event in await service.search(
            SearchQuery(pattern: "cat", matchMode: .matchesWord, caseSensitive: true)
        ) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 1)

        matches = []
        for try await event in await service.search(SearchQuery(pattern: "Cat", caseSensitive: true)) {
            if case .match(let m) = event { matches.append(m) }
        }
        #expect(matches.count == 1)
    }

    @Test func startsWithAndEndsWith() async throws {
        let uri = DocumentURI(rawValue: "inmemory:c")
        let text = "hello world\nworld hello\nhello\n"
        let ctx = WorkspaceSearchContext(openDocuments: [uri: text])
        let service = WorkspaceSearchService(context: ctx)

        var matches: [SearchMatch] = []
        for try await event in await service.search(
            SearchQuery(pattern: "hello", matchMode: .startsWith)
        ) {
            if case .match(let m) = event { matches.append(m) }
        }
        // Lines 0 and 2 start with hello
        #expect(matches.count == 2)

        matches = []
        for try await event in await service.search(
            SearchQuery(pattern: "hello", matchMode: .endsWith)
        ) {
            if case .match(let m) = event { matches.append(m) }
        }
        // Lines 1 ("world hello") and 2 ("hello")
        #expect(matches.count == 2)
    }

    @Test func matchModeLegacyFlags() {
        let regex = SearchQuery(pattern: "a+", isRegex: true)
        #expect(regex.matchMode == .regularExpression)
        let word = SearchQuery(pattern: "a", wholeWord: true)
        #expect(word.matchMode == .matchesWord)
    }

    @Test func preserveCaseTransforms() {
        #expect(SearchReplaceBuilder.applyPreserveCase(matched: "HELLO", replacement: "world") == "WORLD")
        #expect(SearchReplaceBuilder.applyPreserveCase(matched: "hello", replacement: "WORLD") == "world")
        #expect(SearchReplaceBuilder.applyPreserveCase(matched: "Hello", replacement: "world") == "World")
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

    @Test func openDocumentNotDuplicatedOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Main.swift")
        try "Full Full\n".data(using: .utf8)!.write(to: file)

        // Simulate open-document URI that may not string-equal disk URI.
        let openURI = DocumentURI(fileURL: file)
        let ctx = WorkspaceSearchContext(
            rootDirectories: [root],
            openDocuments: [openURI: "Full Full\n"]
        )
        let service = WorkspaceSearchService(context: ctx)
        var matches: [SearchMatch] = []
        var finishedFiles = 0
        var finishedCount = 0
        for try await event in await service.search(SearchQuery(pattern: "Full")) {
            switch event {
            case .match(let m): matches.append(m)
            case .finished(let files, let count):
                finishedFiles = files
                finishedCount = count
            case .progress: break
            }
        }
        #expect(matches.count == 2)
        #expect(finishedCount == 2)
        #expect(finishedFiles == 1)
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
