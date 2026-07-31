import Foundation
import CodeEditorCore
import CodeEditorDocuments

/// Source-control provider backed by the `git` CLI with streaming I/O and path safety.
public final class GitCLIProvider: SourceControlProvider, @unchecked Sendable {
    public let id = "git"
    public var repositoryRoot: URL
    public var executable: URL
    public var platformProfile: PlatformCapabilityProfile
    public var trusted: Bool
    public var auth: (any SCMAuthCallback)?
    private let processService: ProcessService
    private let lock = NSLock()
    private var activeHandle: ProcessHandle?

    public init(
        repositoryRoot: URL,
        executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        platformProfile: PlatformCapabilityProfile = .default(),
        trusted: Bool = true,
        auth: (any SCMAuthCallback)? = nil
    ) {
        self.repositoryRoot = repositoryRoot
        self.executable = executable
        self.platformProfile = platformProfile
        self.trusted = trusted
        self.auth = auth
        self.processService = ProcessService(profile: platformProfile)
    }

    public func status() async throws -> [SCMFileStatus] {
        let data = try await runData(["status", "--porcelain=v1", "-z", "-uall"])
        return GitPorcelain.parseStatusZ(data, repositoryRoot: repositoryRoot)
    }

    public func branches() async throws -> SCMBranchList {
        let output = try await runString(["branch", "--list", "--format=%(refname:short)%00%(HEAD)"])
        var branches: [SCMBranch] = []
        var current: String?
        for entry in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "\0", omittingEmptySubsequences: false)
            guard let name = parts.first.map(String.init), !name.isEmpty else { continue }
            let isCurrent = parts.count > 1 && parts[1] == "*"
            if isCurrent { current = name }
            branches.append(SCMBranch(name: name, isCurrent: isCurrent))
        }
        // Fallback simple list
        if branches.isEmpty {
            let simple = try await runString(["branch", "--list"])
            for line in simple.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("* ") {
                    let name = String(s.dropFirst(2))
                    current = name
                    branches.append(SCMBranch(name: name, isCurrent: true))
                } else if !s.isEmpty {
                    branches.append(SCMBranch(name: s))
                }
            }
        }
        return SCMBranchList(branches: branches, current: current)
    }

    public func tags() async throws -> [SCMTag] {
        let out = try await runString(["tag", "--list"])
        return out.split(separator: "\n").map { SCMTag(name: String($0)) }
    }

    public func remotes() async throws -> [SCMRemote] {
        let out = try await runString(["remote", "-v"])
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            let url = String(parts[1])
            if map[name] == nil { map[name] = url }
        }
        return map.map { SCMRemote(name: $0.key, url: $0.value) }.sorted { $0.name < $1.name }
    }

    public func log(limit: Int = 50) async throws -> [SCMCommit] {
        let out = try await runString([
            "log",
            "-n", "\(max(1, limit))",
            "--format=%H%x00%s%x00%an%x00%ad",
        ])
        var commits: [SCMCommit] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            commits.append(
                SCMCommit(
                    hash: parts[0],
                    subject: parts[1],
                    author: parts.count > 2 ? parts[2] : nil,
                    date: parts.count > 3 ? parts[3] : nil
                )
            )
        }
        return commits
    }

    public func blame(uri: DocumentURI) async throws -> [SCMBlameLine] {
        let path = try relativePath(for: uri)
        let out = try await runString(["blame", "--line-porcelain", "--", path])
        var lines: [SCMBlameLine] = []
        var hash = ""
        var author: String?
        var summary: String?
        var lineNo = 0
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("\t") {
                lineNo += 1
                lines.append(
                    SCMBlameLine(
                        lineNumber: lineNo,
                        commitHash: hash,
                        author: author,
                        summary: summary,
                        content: String(raw.dropFirst())
                    )
                )
            } else if raw.count >= 40, raw[raw.startIndex].isHexDigit {
                hash = String(raw.prefix(40))
            } else if raw.hasPrefix("author ") {
                author = String(raw.dropFirst(7))
            } else if raw.hasPrefix("summary ") {
                summary = String(raw.dropFirst(8))
            }
        }
        return lines
    }

    public func diff(uri: DocumentURI) async throws -> SCMDiff {
        let path = try relativePath(for: uri)
        let raw = try await runString(["diff", "--", path])
        return GitPorcelain.parseDiff(raw, path: path)
    }

    public func stage(uris: [DocumentURI]) async throws {
        try requireTrusted()
        let paths = try uris.map { try relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await runString(["add", "--"] + paths)
    }

    public func unstage(uris: [DocumentURI]) async throws {
        try requireTrusted()
        let paths = try uris.map { try relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await runString(["restore", "--staged", "--"] + paths)
    }

    public func discard(uris: [DocumentURI]) async throws {
        try requireTrusted()
        let paths = try uris.map { try relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await runString(["checkout", "--"] + paths)
    }

    public func stageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try requireTrusted()
        let path = try relativePath(for: uri)
        let patch = makePatch(path: path, hunk: hunk)
        try await applyPatch(patch, cached: true, reverse: false)
    }

    public func unstageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try requireTrusted()
        let path = try relativePath(for: uri)
        let patch = makePatch(path: path, hunk: hunk)
        try await applyPatch(patch, cached: true, reverse: true)
    }

    public func discardHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try requireTrusted()
        let path = try relativePath(for: uri)
        let patch = makePatch(path: path, hunk: hunk)
        try await applyPatch(patch, cached: false, reverse: true)
    }

    public func commit(message: String) async throws {
        try requireTrusted()
        _ = try await runString(["commit", "-m", message])
    }

    public func checkout(branch: String) async throws {
        try requireTrusted()
        _ = try await runString(["checkout", branch])
    }

    public func createBranch(_ name: String) async throws {
        try requireTrusted()
        _ = try await runString(["branch", name])
    }

    public func deleteBranch(_ name: String) async throws {
        try requireTrusted()
        _ = try await runString(["branch", "-d", name])
    }

    public func fetch(remote: String?) async throws {
        try requireTrusted()
        var args = ["fetch"]
        if let remote { args.append(remote) }
        _ = try await runString(args)
    }

    public func pull(remote: String?, branch: String?) async throws {
        try requireTrusted()
        var args = ["pull"]
        if let remote { args.append(remote) }
        if let branch { args.append(branch) }
        _ = try await runString(args)
    }

    public func push(remote: String?, branch: String?) async throws {
        try requireTrusted()
        var args = ["push"]
        if let remote { args.append(remote) }
        if let branch { args.append(branch) }
        _ = try await runString(args)
    }

    public func resolveConflict(uri: DocumentURI, side: SCMConflictSide) async throws {
        try requireTrusted()
        let path = try relativePath(for: uri)
        switch side {
        case .ours:
            _ = try await runString(["checkout", "--ours", "--", path])
        case .theirs:
            _ = try await runString(["checkout", "--theirs", "--", path])
        case .base:
            throw SCMError.unsupported("resolveConflict base")
        }
        _ = try await runString(["add", "--", path])
    }

    public func cancel() async {
        takeActiveHandle()?.cancel()
    }

    nonisolated private func takeActiveHandle() -> ProcessHandle? {
        lock.lock()
        let handle = activeHandle
        lock.unlock()
        return handle
    }

    nonisolated private func setActiveHandle(_ handle: ProcessHandle?) {
        lock.lock()
        activeHandle = handle
        lock.unlock()
    }

    // MARK: - Private

    private func requireTrusted() throws {
        if !trusted { throw SCMError.untrusted }
    }

    private func relativePath(for uri: DocumentURI) throws -> String {
        guard let path = uri.fileURL?.path else {
            // Allow inmemory relative raw values for tests
            if !uri.rawValue.hasPrefix("file:") {
                return try GitRepositoryDiscovery.validateRelativePath(uri.rawValue, root: repositoryRoot)
            }
            throw SCMError.notFound(uri.rawValue)
        }
        let root = repositoryRoot.standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        guard full.hasPrefix(root) else {
            throw SCMError.pathEscape(path)
        }
        var rel = String(full.dropFirst(root.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return try GitRepositoryDiscovery.validateRelativePath(rel, root: repositoryRoot)
    }

    private func makePatch(path: String, hunk: SCMDiffHunk) -> String {
        var lines = [
            "diff --git a/\(path) b/\(path)",
            "--- a/\(path)",
            "+++ b/\(path)",
            hunk.header,
        ]
        lines.append(contentsOf: hunk.lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private func applyPatch(_ patch: String, cached: Bool, reverse: Bool) async throws {
        var args = ["apply"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("--unidiff-zero")
        args.append("-")
        // Use process with stdin — ProcessService doesn't expose stdin yet; use temp file
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).diff")
        try patch.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var fileArgs = ["apply"]
        if cached { fileArgs.append("--cached") }
        if reverse { fileArgs.append("--reverse") }
        fileArgs.append(tmp.path)
        _ = try await runString(fileArgs)
    }

    private func runString(_ arguments: [String]) async throws -> String {
        let data = try await runData(arguments)
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private func runData(_ arguments: [String]) async throws -> Data {
        try platformProfile.requireLocal(.localGitCLI)
        let request = ProcessLaunchRequest(
            executable: executable.path,
            arguments: arguments,
            mode: .direct,
            currentDirectory: repositoryRoot,
            environment: [:],
            mergeEnvironment: true,
            timeout: .seconds(120),
            capabilityKind: .localGitCLI
        )
        let handle = try processService.launch(request)
        setActiveHandle(handle)
        var out = Data()
        var err = Data()
        var code: Int32 = -1
        for await event in handle.events {
            switch event {
            case .stdout(let d): out.append(d)
            case .stderr(let d): err.append(d)
            case .exited(let c, let timedOut):
                if timedOut { throw SCMError.failed("timeout") }
                code = c
            }
        }
        setActiveHandle(nil)
        if code != 0 {
            let e = String(data: err, encoding: .utf8) ?? String(decoding: err, as: UTF8.self)
            if e.lowercased().contains("not a git repository") {
                throw SCMError.notARepository
            }
            throw SCMError.failed(e.isEmpty ? "git exit \(code)" : e)
        }
        return out
    }
}
