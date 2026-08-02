import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorSearch

// MARK: - SRCH-N01 nested .gitignore discovery

@Suite("SRCH-N01 nested gitignore discovery")
struct SRCHN01NestedGitIgnoreTests {
    @Test func test_SRCH_N01_nestedGitIgnoreIsDiscoveredDespiteHiddenName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n01-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("pkg/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "visible.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "nested-secret.txt\n".write(
            to: nested.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "root-ok".write(to: root.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try "root-vis".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "nested-ok".write(to: nested.appendingPathComponent("ok2.txt"), atomically: true, encoding: .utf8)
        try "nested-sec".write(
            to: nested.appendingPathComponent("nested-secret.txt"),
            atomically: true,
            encoding: .utf8
        )

        let rules = GitIgnoreLoader.load(root: root)
        // Nested base path must be present (discovery must not skip hidden `.gitignore`).
        #expect(rules.rules.contains { $0.basePath.contains("pkg") && $0.pattern.contains("nested-secret") })
        #expect(rules.isIgnored(relativePath: "visible.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "pkg/deep/nested-secret.txt", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "ok.txt", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "pkg/deep/ok2.txt", isDirectory: false))
    }

    @Test func test_SRCH_N01_searchRespectsNestedGitIgnore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n01s-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "hide_me.txt\n".write(to: nested.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "tokenAAA".write(to: nested.appendingPathComponent("show_me.txt"), atomically: true, encoding: .utf8)
        try "tokenAAA".write(to: nested.appendingPathComponent("hide_me.txt"), atomically: true, encoding: .utf8)

        let service = WorkspaceSearchService(
            context: WorkspaceSearchContext(rootDirectories: [root]),
            backendOptions: NativeSearchBackend(respectGitIgnore: true)
        )
        var names: [String] = []
        for try await event in service.search(SearchQuery(pattern: "tokenAAA")) {
            if case .match(let m) = event {
                names.append(m.uri.fileURL?.lastPathComponent ?? "")
            }
        }
        #expect(names.contains("show_me.txt"))
        #expect(!names.contains("hide_me.txt"))
    }
}

// MARK: - SRCH-N02 gitignore semantics

@Suite("SRCH-N02 gitignore corpus")
struct SRCHN02GitIgnoreSemanticsTests {
    @Test func test_SRCH_N02_escapedHashAndBang() {
        let rules = GitIgnoreRules.parse(
            fileContents: """
                \\#not-a-comment.txt
                \\!literal-bang.txt
                # real comment
                normal.txt
                """
        )
        #expect(rules.isIgnored(relativePath: "#not-a-comment.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "!literal-bang.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "normal.txt", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "other.txt", isDirectory: false))
    }

    @Test func test_SRCH_N02_trailingSpacesAndEscapedSpace() {
        // Unescaped trailing spaces are stripped; escaped trailing space is significant.
        let rules = GitIgnoreRules.parse(
            fileContents: "foo.txt   \nbar.txt\\ \n"
        )
        #expect(rules.isIgnored(relativePath: "foo.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "bar.txt ", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "bar.txt", isDirectory: false))
    }

    @Test func test_SRCH_N02_leadingSlashAnchoring() {
        let rules = GitIgnoreRules.parse(
            fileContents: """
                /rooted.txt
                unrooted.txt
                """
        )
        #expect(rules.isIgnored(relativePath: "rooted.txt", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "sub/rooted.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "unrooted.txt", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "sub/unrooted.txt", isDirectory: false))
    }

    @Test func test_SRCH_N02_directoryOnlyAndNegationUnderParent() {
        // Git: cannot re-include a child while the parent directory remains ignored.
        let blocked = GitIgnoreRules.parse(
            fileContents: """
                build/
                !build/keep.txt
                """
        )
        #expect(blocked.isIgnored(relativePath: "build", isDirectory: true))
        #expect(blocked.isIgnored(relativePath: "build/keep.txt", isDirectory: false))

        // Un-ignore parent contents first, then re-include a file (git-compatible).
        let rules = GitIgnoreRules.parse(
            fileContents: """
                build/*
                !build/keep/
                !build/keep/**
                """
        )
        #expect(rules.isIgnored(relativePath: "build/out.o", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "build/keep", isDirectory: true))
        #expect(!rules.isIgnored(relativePath: "build/keep/file.c", isDirectory: false))
    }

    @Test func test_SRCH_N02_characterClassesAndDoubleStar() {
        let rules = GitIgnoreRules.parse(
            fileContents: """
                *.log
                logs/**
                [abc].txt
                """
        )
        #expect(rules.isIgnored(relativePath: "a.log", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "logs/deep/x", isDirectory: false))
        #expect(rules.isIgnored(relativePath: "a.txt", isDirectory: false))
        #expect(!rules.isIgnored(relativePath: "d.txt", isDirectory: false))
    }

    @Test func test_SRCH_N02_matchesGitCheckIgnoreCorpus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n02-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Initialize a real git repo for ground truth.
        try runGit(["init"], in: root)
        try """
            # comment
            *.tmp
            /anchored.dat
            build/*
            !build/keep.txt
            \\#hash.txt
            docs/**
            !docs/readme.md
            [xy].c
            """.write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let nested = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "local.secret\n".write(
            to: nested.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )

        // Create probe paths (files + dirs) so git check-ignore can evaluate.
        let probes: [(rel: String, isDir: Bool)] = [
            ("a.tmp", false),
            ("anchored.dat", false),
            ("deep/anchored.dat", false),
            ("build", true),
            ("build/out.o", false),
            ("build/keep.txt", false),
            ("#hash.txt", false),
            ("docs/x/y.md", false),
            ("docs/readme.md", false),
            ("x.c", false),
            ("z.c", false),
            ("sub/local.secret", false),
            ("sub/ok.txt", false),
            ("ok.txt", false),
        ]
        for p in probes {
            let url = root.appendingPathComponent(p.rel)
            if p.isDir {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }

        let rules = GitIgnoreLoader.load(root: root)
        for p in probes {
            let gitIgnored = try gitCheckIgnore(relativePath: p.rel, in: root)
            let ours = rules.isIgnored(relativePath: p.rel, isDirectory: p.isDir)
            #expect(
                ours == gitIgnored,
                "path=\(p.rel) isDir=\(p.isDir) ours=\(ours) git=\(gitIgnored)"
            )
        }
    }

    private func runGit(_ args: [String], in directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        proc.currentDirectoryURL = directory
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(
                domain: "SRCH-N02",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"]
            )
        }
    }

    /// Returns true when `git check-ignore -q path` exits 0 (ignored).
    private func gitCheckIgnore(relativePath: String, in root: URL) throws -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["check-ignore", "-q", "--no-index", relativePath]
        proc.currentDirectoryURL = root
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        // 0 = ignored, 1 = not ignored
        if proc.terminationStatus == 0 { return true }
        if proc.terminationStatus == 1 { return false }
        throw NSError(
            domain: "SRCH-N02",
            code: Int(proc.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "git check-ignore unexpected status"]
        )
    }
}

// MARK: - SRCH-N03 workspace glob grammar

@Suite("SRCH-N03 workspace glob")
struct SRCHN03WorkspaceGlobTests {
    @Test func test_SRCH_N03_globIsSeparateFromGitIgnore() {
        // Gitignore basename `*.swift` matches any depth; workspace glob without **/ does not.
        let gi = GitIgnoreRules.parse(fileContents: "*.swift\n")
        #expect(gi.isIgnored(relativePath: "a/b/c.swift", isDirectory: false))

        let glob = WorkspaceGlobPattern("*.swift", caseSensitive: false)
        #expect(glob.matches("c.swift"))
        #expect(!glob.matches("a/b/c.swift"))
        #expect(WorkspaceGlobPattern("**/*.swift", caseSensitive: false).matches("a/b/c.swift"))
    }

    @Test func test_SRCH_N03_questionMarkClassesAnchoring() {
        #expect(WorkspaceGlobPattern("?.txt", caseSensitive: true).matches("a.txt"))
        #expect(!WorkspaceGlobPattern("?.txt", caseSensitive: true).matches("ab.txt"))
        #expect(WorkspaceGlobPattern("[abc].c", caseSensitive: true).matches("b.c"))
        #expect(!WorkspaceGlobPattern("[abc].c", caseSensitive: true).matches("d.c"))
        #expect(WorkspaceGlobPattern("/rooted.txt", caseSensitive: true).matches("rooted.txt"))
        #expect(!WorkspaceGlobPattern("/rooted.txt", caseSensitive: true).matches("x/rooted.txt"))
        // Case policy
        #expect(WorkspaceGlobPattern("Foo.SWIFT", caseSensitive: false).matches("foo.swift"))
        #expect(!WorkspaceGlobPattern("Foo.SWIFT", caseSensitive: true).matches("foo.swift"))
    }

    @Test func test_SRCH_N03_includeExcludeFilters() {
        let path = "Sources/App/Main.swift"
        #expect(
            WorkspaceGlobMatcher.isIncluded(
                path: path,
                includes: ["**/*.swift"],
                caseSensitive: false
            )
        )
        #expect(
            !WorkspaceGlobMatcher.isIncluded(
                path: path,
                includes: ["**/*.md"],
                caseSensitive: false
            )
        )
        #expect(
            WorkspaceGlobMatcher.isExcluded(
                path: "node_modules/x.js",
                excludes: ["**/node_modules/**"],
                caseSensitive: false
            )
        )
    }
}

// MARK: - SRCH-N04 worker pool + cancellation

@Suite("SRCH-N04 bounded workers")
struct SRCHN04WorkerPoolTests {
    @Test func test_SRCH_N04_searchCancelsWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Many files so cancellation can land mid-scan.
        for i in 0..<80 {
            try "needle-\(i)".write(
                to: root.appendingPathComponent("f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let service = WorkspaceSearchService(
            context: WorkspaceSearchContext(rootDirectories: [root]),
            backendOptions: NativeSearchBackend(maxConcurrentWorkers: 2)
        )
        let stream = service.search(SearchQuery(pattern: "needle", maxResults: 10_000))
        let task = Task<Int, Error> {
            var count = 0
            for try await event in stream {
                if case .match = event { count += 1 }
            }
            return count
        }
        // Cancel quickly after first progress opportunity.
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        let start = ContinuousClock.now
        let result = try? await task.value
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(200))
        // Cancellation may yield partial count or throw; must not hang.
        _ = result
    }

    @Test func test_SRCH_N04_independentSubscriptions() async throws {
        let uri = DocumentURI(rawValue: "inmemory:n04")
        let ctx = WorkspaceSearchContext(openDocuments: [uri: "alpha beta gamma"])
        let service = WorkspaceSearchService(context: ctx)
        async let a: Int = {
            var n = 0
            for try await event in service.search(SearchQuery(pattern: "a")) {
                if case .match = event { n += 1 }
            }
            return n
        }()
        async let b: Int = {
            var n = 0
            for try await event in service.search(SearchQuery(pattern: "a")) {
                if case .match = event { n += 1 }
            }
            return n
        }()
        let (na, nb) = try await (a, b)
        #expect(na == nb)
        #expect(na > 0)
    }
}

// MARK: - SRCH-N05 encoding-aware skip reporting

@Suite("SRCH-N05 encoding skips")
struct SRCHN05EncodingSkipTests {
    @Test func test_SRCH_N05_nonUTF8IsReportedNotSilent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Invalid UTF-8 sequence (lone 0xFF) — DocumentCodec must reject, search reports skip.
        let bad = Data([0x48, 0x69, 0xFF, 0x21]) // "Hi" + invalid + "!"
        try bad.write(to: root.appendingPathComponent("bad.txt"))
        try "tokenUTF8".write(to: root.appendingPathComponent("good.txt"), atomically: true, encoding: .utf8)

        let service = WorkspaceSearchService(context: WorkspaceSearchContext(rootDirectories: [root]))
        var skips: [SearchSkip] = []
        var matchNames: [String] = []
        var metrics: SearchCompletionMetrics?
        for try await event in service.search(SearchQuery(pattern: "tokenUTF8")) {
            switch event {
            case .skipped(let s): skips.append(s)
            case .match(let m): matchNames.append(m.uri.fileURL?.lastPathComponent ?? "")
            case .finished(let m): metrics = m
            case .progress: break
            }
        }
        #expect(matchNames.contains("good.txt"))
        #expect(skips.contains { $0.path.hasSuffix("bad.txt") })
        #expect(skips.contains { $0.reason == .encodingFailed || $0.reason == .unsupportedEncoding })
        #expect((metrics?.skipped ?? 0) >= 1)
    }

    @Test func test_SRCH_N05_utf16BOMIsDecoded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n05u-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let text = "findMeUTF16"
        var data = Data([0xFF, 0xFE]) // LE BOM
        data.append(contentsOf: text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        try data.write(to: root.appendingPathComponent("u16.txt"))

        let service = WorkspaceSearchService(context: WorkspaceSearchContext(rootDirectories: [root]))
        var matches = 0
        for try await event in service.search(SearchQuery(pattern: "findMeUTF16")) {
            if case .match = event { matches += 1 }
        }
        #expect(matches == 1)
    }
}

// MARK: - SRCH-N06 bounded regex

@Suite("SRCH-N06 regex bounds")
struct SRCHN06RegexBudgetTests {
    @Test func test_SRCH_N06_perFileMatchLimit() async throws {
        let uri = DocumentURI(rawValue: "inmemory:n06")
        // Many matches of "a"
        let text = String(repeating: "a ", count: 500)
        let ctx = WorkspaceSearchContext(openDocuments: [uri: text])
        let service = WorkspaceSearchService(
            context: ctx,
            backendOptions: NativeSearchBackend(maxMatchesPerFile: 10)
        )
        var matchCount = 0
        var skips: [SearchSkip] = []
        for try await event in service.search(SearchQuery(pattern: "a", maxResults: 10_000)) {
            switch event {
            case .match: matchCount += 1
            case .skipped(let s): skips.append(s)
            default: break
            }
        }
        #expect(matchCount == 10)
        #expect(skips.contains { $0.reason == .matchLimitExceeded })
    }

    @Test func test_SRCH_N06_rejectsEmptyOrHugeInputPolicy() async throws {
        let uri = DocumentURI(rawValue: "inmemory:n06b")
        let huge = String(repeating: "x", count: 100)
        let ctx = WorkspaceSearchContext(openDocuments: [uri: huge])
        let service = WorkspaceSearchService(
            context: ctx,
            backendOptions: NativeSearchBackend(maxFileBytes: 50)
        )
        var skips: [SearchSkip] = []
        for try await event in service.search(SearchQuery(pattern: "x", maxFileBytes: 50)) {
            if case .skipped(let s) = event { skips.append(s) }
        }
        #expect(skips.contains { $0.reason == .tooLarge })
    }
}

// MARK: - SRCH-N07 completion metrics

@Suite("SRCH-N07 metrics")
struct SRCHN07MetricsTests {
    @Test func test_SRCH_N07_filesScannedCountsAllScannedNotOnlyMatches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "has-hit".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "nope".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "also-no".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let service = WorkspaceSearchService(context: WorkspaceSearchContext(rootDirectories: [root]))
        var metrics: SearchCompletionMetrics?
        var matchCount = 0
        for try await event in service.search(SearchQuery(pattern: "has-hit")) {
            switch event {
            case .match: matchCount += 1
            case .finished(let m): metrics = m
            default: break
            }
        }
        let m = try #require(metrics)
        #expect(matchCount == 1)
        // Scanned must include files without matches.
        #expect(m.scanned >= 3)
        #expect(m.matched == 1)
        #expect(m.matchCount == 1)
        #expect(m.discovered >= 3)
        #expect(m.eligible >= 3)
        #expect(m.decoded >= 3)
        // Legacy alias: filesScanned == scanned (not files-with-matches).
        #expect(m.filesScanned == m.scanned)
        #expect(m.filesScanned != m.matched || m.scanned == m.matched)
    }
}

// MARK: - SRCH-N08 regex replacement

@Suite("SRCH-N08 regex replace")
struct SRCHN08RegexReplaceTests {
    @Test func test_SRCH_N08_numberedAndNamedCaptures() throws {
        let text = "hello world"
        let match = SearchMatch(
            uri: DocumentURI(rawValue: "file:///t.txt"),
            range: TextRange(location: 0, length: 11),
            line: 0,
            column: 0,
            preview: text,
            fromOpenDocument: true
        )
        let q = SearchQuery(pattern: "(?<first>\\w+) (\\w+)", matchMode: .regularExpression)
        let numbered = try SearchReplaceBuilder.replacementText(
            for: match,
            template: "$2-$1",
            query: q,
            fullText: text
        )
        #expect(numbered == "world-hello")

        let named = try SearchReplaceBuilder.replacementText(
            for: match,
            template: "${first}!",
            query: q,
            fullText: text
        )
        #expect(named == "hello!")
    }

    @Test func test_SRCH_N08_dollarEscaping() throws {
        let text = "abc"
        let match = SearchMatch(
            uri: DocumentURI(rawValue: "file:///t.txt"),
            range: TextRange(location: 0, length: 3),
            line: 0,
            column: 0,
            preview: text,
            fromOpenDocument: true
        )
        let q = SearchQuery(pattern: "(a)(b)(c)", matchMode: .regularExpression)
        let escaped = try SearchReplaceBuilder.replacementText(
            for: match,
            template: "$$0=$0",
            query: q,
            fullText: text
        )
        #expect(escaped == "$0=abc")
    }

    @Test func test_SRCH_N08_zeroWidthMatchProgress() throws {
        // Zero-width anchors: replace between each character without infinite loop.
        let text = "ab"
        let uri = DocumentURI(rawValue: "file:///zw.txt")
        let q = SearchQuery(pattern: "(?=.)", matchMode: .regularExpression)
        let regex = try NSRegularExpression(pattern: "(?=.)")
        let ns = text as NSString
        var matches: [SearchMatch] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            result, _, _ in
            guard let result else { return }
            matches.append(
                SearchMatch(
                    uri: uri,
                    range: TextRange(location: result.range.location, length: result.range.length),
                    line: 0,
                    column: result.range.location,
                    preview: text,
                    fromOpenDocument: true
                )
            )
        }
        #expect(matches.count == 2)
        let plan = SearchReplacePlan(query: q, replacement: "X", matches: matches)
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            openDocumentVersions: [uri: DocumentVersion(rawValue: 1)],
            documentTexts: [uri: text]
        )
        #expect(edit.documentChanges.count == 1)
        #expect(edit.documentChanges[0].transaction.changes.count == 2)
    }

    @Test func test_SRCH_N08_noSecondFindFallbackWrongOccurrence() throws {
        // Preview line has the pattern twice; match range points at second occurrence only.
        let text = "foo bar foo"
        // Second "foo" at UTF-16 offset 8.
        let match = SearchMatch(
            uri: DocumentURI(rawValue: "file:///f.txt"),
            range: TextRange(location: 8, length: 3),
            line: 0,
            column: 8,
            preview: text,
            fromOpenDocument: true
        )
        let q = SearchQuery(pattern: "(foo)", matchMode: .regularExpression)
        let replaced = try SearchReplaceBuilder.replacementText(
            for: match,
            template: "[$1]",
            query: q,
            fullText: text
        )
        #expect(replaced == "[foo]")
        // Applying only that range must not rewrite the first foo.
        let plan = SearchReplacePlan(query: q, replacement: "[$1]", matches: [match])
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            documentTexts: [match.uri: text]
        )
        let change = edit.documentChanges[0].transaction.changes[0]
        #expect(change.replacedRange.location == 8)
        #expect(change.replacement == "[foo]")
    }

    @Test func test_SRCH_N08_requiresPinnedTextForRegexReplace() {
        let match = SearchMatch(
            uri: DocumentURI(rawValue: "file:///f.txt"),
            range: TextRange(location: 0, length: 3),
            line: 0,
            column: 0,
            preview: "foo bar foo",
            fromOpenDocument: true
        )
        let q = SearchQuery(pattern: "(foo)", matchMode: .regularExpression)
        #expect(throws: SearchReplaceError.self) {
            _ = try SearchReplaceBuilder.replacementText(
                for: match,
                template: "$1",
                query: q,
                fullText: nil
            )
        }
    }
}

// MARK: - SRCH-N09 snapshot-bound multi-file replace

@Suite("SRCH-N09 snapshot-bound replace")
@MainActor
struct SRCHN09SnapshotReplaceTests {
    @Test func test_SRCH_N09_previewPinsContentStateAndRejectsStaleCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = try await LocalWorkspaceFileSystem(rootDirectories: [root], enablesDirectoryWatching: false)
        let ws = Workspace(fileSystem: fs)
        let docA = TextDocument(text: "alpha alpha")
        let docB = TextDocument(text: "beta beta")
        try await ws.lifecycle.openExisting(docA)
        try await ws.lifecycle.openExisting(docB)

        let matches = [
            SearchMatch(
                uri: docA.uri,
                range: TextRange(location: 0, length: 5),
                line: 0,
                column: 0,
                preview: docA.text,
                fromOpenDocument: true
            ),
            SearchMatch(
                uri: docB.uri,
                range: TextRange(location: 0, length: 4),
                line: 0,
                column: 0,
                preview: docB.text,
                fromOpenDocument: true
            ),
        ]

        // Preview pins versions/content states/texts.
        let pinned = SearchReplaceService.pin(
            matches: matches,
            from: ws,
            query: SearchQuery(pattern: "alpha|beta", matchMode: .regularExpression),
            replacement: "Z"
        )
        #expect(pinned.documents.count == 2)
        #expect(pinned.documents[docA.uri]?.contentState == docA.contentState)
        #expect(pinned.documents[docB.uri]?.contentState == docB.contentState)

        // Mutate after pin → commit must fail closed (conflict / version mismatch), no partial apply.
        _ = try docA.apply(.single(range: NSRange(location: 0, length: 0), replacement: "!"))
        do {
            _ = try await SearchReplaceService.commit(pinned: pinned, to: ws)
            Issue.record("expected stale pin rejection")
        } catch is SearchReplaceError {
            // ok
        } catch is WorkspaceEditError {
            // ok — version/conflict surface
        }
        // B must be untouched; A only has intentional mutation prefix.
        #expect(docB.text == "beta beta")
        #expect(docA.text.hasPrefix("!"))
        #expect(!docA.text.hasPrefix("Z"))
    }

    @Test func test_SRCH_N09_commitAppliesExactlyToPinnedStates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("srch-n09b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = try await LocalWorkspaceFileSystem(rootDirectories: [root], enablesDirectoryWatching: false)
        let ws = Workspace(fileSystem: fs)
        let docA = TextDocument(text: "one one")
        let docB = TextDocument(text: "two two")
        try await ws.lifecycle.openExisting(docA)
        try await ws.lifecycle.openExisting(docB)

        let matches = [
            SearchMatch(
                uri: docA.uri,
                range: TextRange(location: 0, length: 3),
                line: 0,
                column: 0,
                preview: docA.text,
                fromOpenDocument: true
            ),
            SearchMatch(
                uri: docA.uri,
                range: TextRange(location: 4, length: 3),
                line: 0,
                column: 4,
                preview: docA.text,
                fromOpenDocument: true
            ),
            SearchMatch(
                uri: docB.uri,
                range: TextRange(location: 0, length: 3),
                line: 0,
                column: 0,
                preview: docB.text,
                fromOpenDocument: true
            ),
        ]
        let pinned = SearchReplaceService.pin(
            matches: matches,
            from: ws,
            query: SearchQuery(pattern: "one|two", matchMode: .regularExpression),
            replacement: "XX"
        )
        let result = try await SearchReplaceService.commit(pinned: pinned, to: ws)
        #expect(result.appliedDocumentChanges.count == 2)
        #expect(docA.text == "XX XX")
        #expect(docB.text.hasPrefix("XX"))
    }
}
