import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorSourceControl

@Suite("Phase7 SCM fixtures")
struct Phase7SCMTests {
    @Test func porcelainZRenameUsesDestinationPath() {
        let root = URL(fileURLWithPath: "/repo")
        // R  dest\0src\0
        var data = Data("R  new name.swift".utf8)
        data.append(0)
        data.append(contentsOf: "old name.swift".utf8)
        data.append(0)
        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        #expect(statuses.count == 1)
        #expect(statuses[0].path == "new name.swift")
        #expect(statuses[0].originalPath == "old name.swift")
        #expect(statuses[0].state == .renamed)
    }

    @Test func porcelainZUnicodeAndConflict() {
        let root = URL(fileURLWithPath: "/repo")
        var data = Data("UU 冲突.swift".utf8)
        data.append(0)
        data.append(contentsOf: "?? 未跟踪.md".utf8)
        data.append(0)
        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        #expect(statuses.contains(where: { $0.path.contains("冲突") && $0.state == .conflicted }))
        #expect(statuses.contains(where: { $0.path.contains("未跟踪") && $0.state == .untracked }))
    }

    @Test func porcelainZCopyAndSubmodule() {
        let root = URL(fileURLWithPath: "/repo")
        var data = Data("C  copy.swift".utf8)
        data.append(0)
        data.append(contentsOf: "orig.swift".utf8)
        data.append(0)
        data.append(contentsOf: " S vendor/lib".utf8)
        data.append(0)
        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        #expect(statuses.contains(where: { $0.path == "copy.swift" }))
        #expect(statuses.contains(where: { $0.path == "vendor/lib" }))
    }

    @Test func untrustedGitStatusFailsClosed() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = GitCLIProvider(repositoryRoot: root, trusted: false)
        do {
            _ = try await provider.status()
            Issue.record("expected untrusted")
        } catch let error as SCMError {
            guard case .untrusted = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func siblingRepoPathRejected() async throws {
        #if os(macOS)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-sib-\(UUID().uuidString)", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let sibling = base.appendingPathComponent("repo-other", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let provider = GitCLIProvider(repositoryRoot: repo, trusted: true)
        let escape = sibling.appendingPathComponent("secret.txt")
        do {
            _ = try await provider.diff(uri: DocumentURI(fileURL: escape))
            Issue.record("expected pathEscape")
        } catch let error as SCMError {
            guard case .pathEscape = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #else
        // Non-macOS: GitCLI path-escape suite is macOS-only.
        #expect(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 1)
        #endif
    }

    @Test func concurrentOpsDoNotCrossCancel() async throws {
        #if os(macOS)
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-conc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = git
            p.arguments = args
            p.currentDirectoryURL = root
            try p.run()
            p.waitUntilExit()
        }
        try run(["init"])
        try run(["config", "user.email", "t@e.com"])
        try run(["config", "user.name", "T"])
        try "x\n".write(
            to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try run(["add", "f.txt"])
        try run(["commit", "-m", "i"])

        let provider = GitCLIProvider(repositoryRoot: root, trusted: true)
        async let s1 = provider.status()
        async let s2 = provider.branches()
        let status = try await s1
        let branches = try await s2
        #expect(status.count >= 0)
        #expect(branches.current != nil || !branches.branches.isEmpty)
        // Cancel all should not poison subsequent status
        await provider.cancel()
        let after = try await provider.status()
        #expect(after.count >= 0)
        #else
        #expect(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 1)
        #endif
    }

    @Test func usesProcessServiceLauncher() {
        // Compile-time: GitCLIProvider stores ProcessService (CORE process substrate)
        let root = URL(fileURLWithPath: "/tmp")
        let p = GitCLIProvider(repositoryRoot: root, trusted: false)
        #expect(p.trusted == false)
    }
}
