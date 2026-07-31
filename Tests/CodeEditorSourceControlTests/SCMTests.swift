import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
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
                    ),
                ]
            }
            func branches() async throws -> SCMBranchList {
                SCMBranchList(branches: [SCMBranch(name: "main", isCurrent: true)], current: "main")
            }
            func diff(uri: DocumentURI) async throws -> String { "diff" }
        }
        let service = SourceControlService()
        await service.setProvider(Mock())
        let status = try await service.refresh()
        #expect(status.count == 1)
        let branches = try await service.branches()
        #expect(branches.current == "main")
    }

    @Test func gitCLIWhenAvailable() async throws {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else {
            return // skip
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
            guard p.terminationStatus == 0 else {
                throw SCMError.failed("git \(args) failed")
            }
        }
        try run(["init"])
        try run(["config", "user.email", "test@example.com"])
        try run(["config", "user.name", "Test"])
        try "hello".data(using: .utf8)!.write(to: root.appendingPathComponent("f.txt"))
        try run(["add", "f.txt"])
        try run(["commit", "-m", "init"])
        try "hello world".data(using: .utf8)!.write(to: root.appendingPathComponent("f.txt"))

        let provider = GitCLIProvider(repositoryRoot: root, executable: git)
        let status = try await provider.status()
        #expect(status.contains(where: { $0.path == "f.txt" && $0.state == .modified }))
        let branches = try await provider.branches()
        #expect(branches.current != nil)
    }

    @Test func gitCLIFailsClosedWhenProfileDeniesLocalGit() async {
        let provider = GitCLIProvider(
            repositoryRoot: URL(fileURLWithPath: "/tmp"),
            platformProfile: .processUnavailable
        )
        do {
            _ = try await provider.status()
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .localGitCLI)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
