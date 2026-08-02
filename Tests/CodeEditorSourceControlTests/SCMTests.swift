import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorSourceControl

@Suite("Source Control")
struct SCMTests {
    @Test func porcelainParser() {
        let root = URL(fileURLWithPath: "/repo")
        let text = """
            M  Sources/A.swift
             M Sources/B.swift
            ?? Notes.md
            D  gone.txt
            UU conflict.swift
            """
        let statuses = GitPorcelain.parseStatus(text, repositoryRoot: root)
        #expect(statuses.count == 5)
        let byPath = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })
        #expect(byPath["Sources/A.swift"]?.staged == true)
        #expect(byPath["Sources/A.swift"]?.state == .modified)
        #expect(byPath["Sources/B.swift"]?.staged == false)
        #expect(byPath["Notes.md"]?.state == .untracked)
        #expect(byPath["gone.txt"]?.state == .deleted)
        #expect(byPath["conflict.swift"]?.state == .conflicted)
    }

    @Test func porcelainZParsesSpacesInNames() {
        let root = URL(fileURLWithPath: "/repo")
        // M  path with space\0
        var data = Data(" M path with space".utf8)
        data.append(0)
        data.append(contentsOf: "?? Notes.md".utf8)
        data.append(0)
        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        #expect(statuses.contains(where: { $0.path == "path with space" }))
        #expect(statuses.contains(where: { $0.path == "Notes.md" && $0.state == .untracked }))
    }

    @Test func pathEscapeRejected() {
        let root = URL(fileURLWithPath: "/repo")
        do {
            _ = try GitRepositoryDiscovery.validateRelativePath("../etc/passwd", root: root)
            Issue.record("expected pathEscape")
        } catch let error as SCMError {
            guard case .pathEscape = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func siblingPrefixEscapeRejected() {
        let root = URL(fileURLWithPath: "/repo")
        do {
            _ = try GitRepositoryDiscovery.validateRelativePath("/repo-evil/x", root: root)
            Issue.record("expected pathEscape")
        } catch is SCMError {
            // ok
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func serviceRequiresProvider() async {
        let service = SourceControlService()
        do {
            _ = try await service.refresh()
            Issue.record("expected noProvider")
        } catch let error as SCMError {
            #expect(error == .noProvider)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func serviceRefreshWithMockProvider() async throws {
        struct Mock: SourceControlProvider {
            let id = "mock"
            func status() async throws -> [SCMFileStatus] {
                [
                    SCMFileStatus(
                        uri: DocumentURI(rawValue: "file:///repo/a.swift"),
                        path: "a.swift",
                        state: .modified,
                        staged: false
                    )
                ]
            }
            func branches() async throws -> SCMBranchList {
                SCMBranchList(branches: [SCMBranch(name: "main", isCurrent: true)], current: "main")
            }
            func diff(uri: DocumentURI) async throws -> SCMDiff {
                SCMDiff(path: "a.swift", raw: "diff")
            }
        }
        let service = SourceControlService()
        await service.setProvider(Mock())
        let status = try await service.refresh()
        #expect(status.count == 1)
        let branches = try await service.branches()
        #expect(branches.current == "main")
    }

    @Test func unsupportedDefaultsThrow() async {
        struct Minimal: SourceControlProvider {
            let id = "min"
            func status() async throws -> [SCMFileStatus] { [] }
            func branches() async throws -> SCMBranchList { SCMBranchList() }
        }
        let p = Minimal()
        do {
            try await p.stage(uris: [])
            Issue.record("expected unsupported")
        } catch let error as SCMError {
            guard case .unsupported = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func untrustedBlocksMutation() async {
        struct Mock: SourceControlProvider {
            let id = "mock"
            func status() async throws -> [SCMFileStatus] { [] }
            func branches() async throws -> SCMBranchList { SCMBranchList() }
            func stage(uris: [DocumentURI]) async throws {}
        }
        let service = SourceControlService()
        await service.setProvider(Mock())
        // service.trusted is actor state — use method
        // Directly set via discovering untrusted isn't exposed; set trusted on service
        // We'll call commit path with trusted=false by using GitCLIProvider
        let git = GitCLIProvider(
            repositoryRoot: URL(fileURLWithPath: "/tmp"),
            trusted: false
        )
        do {
            try await git.stage(uris: [])
            Issue.record("expected untrusted")
        } catch let error as SCMError {
            #expect(error == .untrusted)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func parseDiffHunks() {
        let raw = """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -1,2 +1,3 @@
             line1
            -old
            +new
            +extra
            """
        let diff = GitPorcelain.parseDiff(raw, path: "a.swift")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].newStart == 1)
        #expect(diff.hunks[0].lines.contains("+new"))
    }

    @Test func gitCLIWhenAvailable() async throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = git
            p.arguments = args
            p.currentDirectoryURL = root
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }

        try run(["init"])
        try run(["config", "user.email", "test@example.com"])
        try run(["config", "user.name", "Test"])
        let file = root.appendingPathComponent("hello world.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        try run(["add", "hello world.swift"])
        try run(["commit", "-m", "init"])

        let provider = GitCLIProvider(repositoryRoot: root, trusted: true)
        let status = try await provider.status()
        #expect(status.isEmpty || status.allSatisfy { $0.state != .conflicted })

        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8)
        let dirty = try await provider.status()
        #expect(dirty.contains(where: { $0.path == "hello world.swift" }))

        let uri = DocumentURI(fileURL: file)
        try await provider.stage(uris: [uri])
        let staged = try await provider.status()
        #expect(staged.contains(where: { $0.path == "hello world.swift" && $0.staged }))

        // Cancel mid-status shouldn't corrupt; run cancel then status again
        await provider.cancel()
        _ = try await provider.status()

        let branches = try await provider.branches()
        #expect(branches.current != nil)

        let log = try await provider.log(limit: 5)
        #expect(!log.isEmpty)

        // Path escape
        do {
            _ = try await provider.diff(uri: DocumentURI(rawValue: "file:///etc/passwd"))
            Issue.record("expected pathEscape")
        } catch is SCMError {
            // ok
        }

        // Detached HEAD / second commit
        try await provider.commit(message: "second")
        let after = try await provider.status()
        #expect(after.isEmpty)
    }

    @Test func gitCLIFailsClosedWhenProfileDenies() async {
        let provider = GitCLIProvider(
            repositoryRoot: URL(fileURLWithPath: "/tmp"),
            platformProfile: .processUnavailable,
            trusted: true
        )
        do {
            _ = try await provider.status()
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong \(error)")
                return
            }
            #expect(kind == .localGitCLI)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func discoveryFindsRoot() throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = Process()
        p.executableURL = git
        p.arguments = ["init"]
        p.currentDirectoryURL = root
        try p.run()
        p.waitUntilExit()
        let found = GitRepositoryDiscovery.discover(from: nested)
        #expect(found?.path == root.standardizedFileURL.path)
    }
}
