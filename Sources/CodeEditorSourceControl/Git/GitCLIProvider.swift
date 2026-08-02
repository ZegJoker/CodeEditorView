import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Source-control provider backed by the `git` CLI (SCM-N01…N09).
///
/// - Per-repository identity (not constant `"git"`)
/// - Auth via ``SCMAuthCallback`` + GIT_ASKPASS (fail-closed without callback)
/// - Progress via ``AsyncBroadcastHub`` (started / fraction / message / cancelled / finished)
/// - Exclusive mutation gate
/// - Destructive ops require ``SCMDocumentCoordinator`` (fail-closed)
/// - ``ProcessSupervisor`` + bounded stdout/stderr
public actor GitCLIProvider: SourceControlProvider {
    public nonisolated let id: String
    public nonisolated let repositoryIdentity: SCMRepositoryIdentity
    public nonisolated let repositoryRoot: URL
    public nonisolated let executable: URL
    public nonisolated let platformProfile: PlatformCapabilityProfile
    public nonisolated let maxStdoutBytes: Int
    public nonisolated let maxStderrBytes: Int

    public private(set) var trusted: Bool
    public var auth: (any SCMAuthCallback)?
    private var documentCoordinator: SCMDocumentCoordinator?

    public let operationGate: SCMRepositoryGate

    /// Runtime spawn telemetry (SCM-N09 tests assert ProcessSupervisor bounds).
    public private(set) var lastSpawnMaxStdoutBytes: Int?
    public private(set) var lastSpawnMaxStderrBytes: Int?
    public private(set) var lastSpawnUsedProcessSupervisor: Bool = false

    public var hasDocumentCoordinator: Bool { documentCoordinator != nil }

    public func setTrusted(_ value: Bool) {
        trusted = value
    }

    public func setDocumentCoordinator(_ coordinator: SCMDocumentCoordinator?) {
        documentCoordinator = coordinator
    }

    private let supervisor: ProcessSupervisor
    private let progressHub = AsyncBroadcastHub<SCMProgressEvent>(maxHistory: 64)
    private var activeHandles: [UUID: ProcessHandle] = [:]
    private var cancelRequested = false
    private var askpassDir: URL?

    public init(
        repositoryRoot: URL,
        executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        platformProfile: PlatformCapabilityProfile = .default(),
        trusted: Bool = false,
        auth: (any SCMAuthCallback)? = nil,
        documentCoordinator: SCMDocumentCoordinator? = nil,
        maxStdoutBytes: Int = 4 * 1024 * 1024,
        maxStderrBytes: Int = 1 * 1024 * 1024
    ) {
        let identity = SCMRepositoryIdentity.git(repositoryRoot: repositoryRoot)
        self.repositoryIdentity = identity
        self.id = identity.rawValue
        self.repositoryRoot = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        self.executable = executable
        self.platformProfile = platformProfile
        self.trusted = trusted
        self.auth = auth
        self.documentCoordinator = documentCoordinator
        self.maxStdoutBytes = max(1, maxStdoutBytes)
        self.maxStderrBytes = max(1, maxStderrBytes)
        self.operationGate = SCMRepositoryGate()
        self.supervisor = ProcessSupervisor(profile: platformProfile)
    }

    /// Gate identity shared for the life of this provider (SCM-N03).
    public var operationGateID: UUID {
        get async { await operationGate.id }
    }

    // MARK: - Auth (SCM-N02)

    public func resolveCredentials(for request: SCMAuthRequest) async -> SCMCredentials? {
        guard let auth else { return nil }
        return await auth.credentials(for: request)
    }

    public func requireCredentials(for request: SCMAuthRequest) async throws -> SCMCredentials {
        guard let auth else { throw SCMError.authRequired }
        guard let creds = await auth.credentials(for: request) else {
            throw SCMError.authRequired
        }
        return creds
    }

    /// Environment for remote ops: always disable terminal prompt; wire askpass only when auth is set.
    public func gitEnvironmentForRemote(host: String) async -> [String: String] {
        var env: [String: String] = [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        if auth != nil {
            if let askpass = try? ensureAskpassHelper() {
                env["GIT_ASKPASS"] = askpass.path
                env["SSH_ASKPASS"] = askpass.path
                env["GIT_ASKPASS_REQUIRE"] = "force"
                env["SCM_ASKPASS_HOST"] = host
            }
        }
        return env
    }

    // MARK: - Progress (SCM-N03)

    public func makeProgressStream(
        policy: AsyncBroadcastHub<SCMProgressEvent>.OverflowPolicy = .dropOldest(
            capacity: 64, emitGap: true),
        replay: ReplayPolicy = .none
    ) async -> AsyncStream<StreamItem<AsyncBroadcastHub<SCMProgressEvent>.Envelope>> {
        await progressHub.subscribe(policy: policy, replay: replay)
    }

    /// Test helper: finish progress hub so collectors can complete.
    public func finishProgressStreamForTests() async {
        await progressHub.finish(.completed)
    }

    /// Parse git `--progress` / status lines such as `Receiving objects:  45% (123/456)`.
    public nonisolated static func parseGitProgressFraction(_ line: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3})\s*%"#, options: []) else {
            return nil
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = re.firstMatch(in: line, options: [], range: range),
            match.numberOfRanges >= 2,
            let r = Range(match.range(at: 1), in: line),
            let pct = Int(line[r])
        else {
            return nil
        }
        let clamped = min(100, max(0, pct))
        return Double(clamped) / 100.0
    }

    // MARK: - Provider API

    public func status() async throws -> [SCMFileStatus] {
        try await coordinated(operation: "status", category: .read) {
            try self.requireTrusted()
            let data = try await self.runData(["status", "--porcelain=v1", "-z", "-uall"])
            return GitPorcelain.parseStatusZ(data, repositoryRoot: self.repositoryRoot)
        }
    }

    public func branches() async throws -> SCMBranchList {
        try await coordinated(operation: "branches", category: .read) {
            try self.requireTrusted()
            let output = try await self.runString(
                ["branch", "--list", "--format=%(refname:short)%00%(HEAD)"]
            )
            var branches: [SCMBranch] = []
            var current: String?
            for entry in output.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = entry.split(separator: "\0", omittingEmptySubsequences: false)
                guard let name = parts.first.map(String.init), !name.isEmpty else { continue }
                let isCurrent = parts.count > 1 && parts[1] == "*"
                if isCurrent { current = name }
                branches.append(SCMBranch(name: name, isCurrent: isCurrent))
            }
            if branches.isEmpty {
                let simple = try await self.runString(["branch", "--list"])
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
    }

    public func tags() async throws -> [SCMTag] {
        try await coordinated(operation: "tags", category: .read) {
            try self.requireTrusted()
            let out = try await self.runString(["tag", "--list"])
            return out.split(separator: "\n").map { SCMTag(name: String($0)) }
        }
    }

    public func remotes() async throws -> [SCMRemote] {
        try await coordinated(operation: "remotes", category: .read) {
            try self.requireTrusted()
            let out = try await self.runString(["remote", "-v"])
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
    }

    public func log(limit: Int = 50) async throws -> [SCMCommit] {
        try await coordinated(operation: "log", category: .read) {
            try self.requireTrusted()
            let out = try await self.runString([
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
    }

    public func blame(uri: DocumentURI) async throws -> [SCMBlameLine] {
        try await coordinated(operation: "blame", category: .read) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            let out = try await self.runString(["blame", "--line-porcelain", "--", path])
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
    }

    public func diff(uri: DocumentURI) async throws -> SCMDiff {
        try await coordinated(operation: "diff", category: .read) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            let raw = try await self.runString(["diff", "--", path])
            return GitPorcelain.parseDiff(raw, path: path)
        }
    }

    public func stage(uris: [DocumentURI]) async throws {
        try await coordinated(operation: "stage", category: .mutate) {
            try self.requireTrusted()
            let paths = try uris.map { try self.relativePath(for: $0) }
            guard !paths.isEmpty else { return }
            _ = try await self.runString(["add", "--"] + paths)
        }
    }

    public func unstage(uris: [DocumentURI]) async throws {
        try await coordinated(operation: "unstage", category: .mutate) {
            try self.requireTrusted()
            let paths = try uris.map { try self.relativePath(for: $0) }
            guard !paths.isEmpty else { return }
            _ = try await self.runString(["restore", "--staged", "--"] + paths)
        }
    }

    public func discard(uris: [DocumentURI]) async throws {
        try await coordinated(operation: "discard", category: .mutate) {
            try self.requireTrusted()
            let paths = try uris.map { try self.relativePath(for: $0) }
            guard !paths.isEmpty else { return }
            try await self.assertCleanForDestructive(relativePaths: paths)
            _ = try await self.runString(["checkout", "--"] + paths)
        }
    }

    public func stageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try await coordinated(operation: "stageHunk", category: .mutate) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            let patch = try await self.patchForHunk(path: path, hunk: hunk)
            try await self.applyPatch(patch, cached: true, reverse: false)
        }
    }

    public func unstageHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try await coordinated(operation: "unstageHunk", category: .mutate) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            let patch = GitPatchBuilder.makePatch(path: path, hunk: hunk)
            try await self.applyPatch(patch, cached: true, reverse: true)
        }
    }

    public func discardHunk(_ hunk: SCMDiffHunk, uri: DocumentURI) async throws {
        try await coordinated(operation: "discardHunk", category: .mutate) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            try await self.assertCleanForDestructive(relativePaths: [path])
            let patch = GitPatchBuilder.makePatch(path: path, hunk: hunk)
            try await self.applyPatch(patch, cached: false, reverse: true)
        }
    }

    public func commit(message: String) async throws {
        try await coordinated(operation: "commit", category: .mutate) {
            try self.requireTrusted()
            _ = try await self.runString(["commit", "-m", message])
        }
    }

    public func checkout(branch: String) async throws {
        try await coordinated(operation: "checkout", category: .mutate) {
            try self.requireTrusted()
            try await self.assertCleanForDestructive(relativePaths: [])
            _ = try await self.runString(["checkout", branch])
        }
    }

    public func createBranch(_ name: String) async throws {
        try await coordinated(operation: "createBranch", category: .mutate) {
            try self.requireTrusted()
            _ = try await self.runString(["branch", name])
        }
    }

    public func deleteBranch(_ name: String) async throws {
        try await coordinated(operation: "deleteBranch", category: .mutate) {
            try self.requireTrusted()
            _ = try await self.runString(["branch", "-d", name])
        }
    }

    public func fetch(remote: String?) async throws {
        try await coordinated(operation: "fetch", category: .network) {
            try self.requireTrusted()
            try await self.prepareRemoteAuth(remote: remote)
            var args = ["fetch", "--progress"]
            if let remote { args.append(remote) }
            _ = try await self.runString(args, remoteHost: remote ?? "origin")
        }
    }

    public func pull(remote: String?, branch: String?) async throws {
        try await coordinated(operation: "pull", category: .network) {
            try self.requireTrusted()
            try await self.assertCleanForDestructive(relativePaths: [])
            try await self.prepareRemoteAuth(remote: remote)
            var args = ["pull", "--progress"]
            if let remote { args.append(remote) }
            if let branch { args.append(branch) }
            _ = try await self.runString(args, remoteHost: remote ?? "origin")
        }
    }

    public func push(remote: String?, branch: String?) async throws {
        try await coordinated(operation: "push", category: .network) {
            try self.requireTrusted()
            try await self.prepareRemoteAuth(remote: remote)
            var args = ["push", "--progress"]
            if let remote { args.append(remote) }
            if let branch { args.append(branch) }
            _ = try await self.runString(args, remoteHost: remote ?? "origin")
        }
    }

    public func resolveConflict(uri: DocumentURI, side: SCMConflictSide) async throws {
        try await coordinated(operation: "resolveConflict", category: .mutate) {
            try self.requireTrusted()
            let path = try self.relativePath(for: uri)
            try await self.assertCleanForDestructive(relativePaths: [path])
            switch side {
            case .ours:
                _ = try await self.runString(["checkout", "--ours", "--", path])
            case .theirs:
                _ = try await self.runString(["checkout", "--theirs", "--", path])
            case .base:
                throw SCMError.unsupported("resolveConflict base")
            }
            _ = try await self.runString(["add", "--", path])
        }
    }

    public func cancel() async {
        cancelRequested = true
        let handles = Array(activeHandles.values)
        for h in handles {
            h.requestCancellation(escalation: .termThenKill())
        }
    }

    // MARK: - Private

    private func coordinated<T: Sendable>(
        operation: String,
        category: SCMOperationCategory,
        _ body: () async throws -> T
    ) async throws -> T {
        cancelRequested = false
        await progressHub.publish(.started(operation: operation, repositoryID: id))
        await progressHub.publish(.fraction(0))
        await operationGate.acquire(category)
        do {
            let result = try await body()
            await operationGate.release(category)
            await progressHub.publish(.fraction(1))
            await progressHub.publish(.finished(operation: operation, success: true))
            return result
        } catch is CancellationError {
            await operationGate.release(category)
            await progressHub.publish(.cancelled(operation: operation))
            throw SCMError.cancelled
        } catch let error as SCMError where error == .cancelled {
            await operationGate.release(category)
            await progressHub.publish(.cancelled(operation: operation))
            throw error
        } catch {
            await operationGate.release(category)
            if cancelRequested {
                await progressHub.publish(.cancelled(operation: operation))
                throw SCMError.cancelled
            }
            await progressHub.publish(.finished(operation: operation, success: false))
            throw error
        }
    }

    private func requireTrusted() throws {
        if !trusted { throw SCMError.untrusted }
    }

    /// SCM-N06 provider-layer preflight — never soft-return when unbound.
    private func assertCleanForDestructive(relativePaths: [String]) async throws {
        guard let coordinator = documentCoordinator else {
            throw SCMError.documentCoordinatorRequired
        }
        try await coordinator.assertClean(
            repositoryRoot: repositoryRoot,
            relativePaths: relativePaths
        )
    }

    private func relativePath(for uri: DocumentURI) throws -> String {
        guard let path = uri.fileURL?.path else {
            if !uri.rawValue.hasPrefix("file:") {
                return try GitRepositoryDiscovery.validateRelativePath(uri.rawValue, root: repositoryRoot)
            }
            throw SCMError.notFound(uri.rawValue)
        }
        let root = repositoryRoot.standardizedFileURL
        let full = URL(fileURLWithPath: path).standardizedFileURL
        let rootParts = root.pathComponents
        let fullParts = full.pathComponents
        guard fullParts.count >= rootParts.count,
            Array(fullParts.prefix(rootParts.count)) == rootParts
        else {
            throw SCMError.pathEscape(path)
        }
        var rel = String(full.path.dropFirst(root.path.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return try GitRepositoryDiscovery.validateRelativePath(rel, root: repositoryRoot)
    }

    /// Build a Git-validated patch: prefer extracting the matching hunk from live `git diff`.
    private func patchForHunk(path: String, hunk: SCMDiffHunk) async throws -> String {
        let raw = try await runString(["diff", "--", path])
        if !raw.isEmpty {
            if let extracted = Self.extractHunkPatch(from: raw, matching: hunk, path: path) {
                return extracted
            }
        }
        return GitPatchBuilder.makePatch(path: path, hunk: hunk)
    }

    /// Extract a single-hunk unified diff from full `git diff` output.
    nonisolated private static func extractHunkPatch(
        from raw: String,
        matching hunk: SCMDiffHunk,
        path: String
    ) -> String? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var header: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("diff --git") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("index ") || line.hasPrefix("old mode") || line.hasPrefix("new mode")
                || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
                || line.hasPrefix("rename to") || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            {
                header.append(line)
                i += 1
                continue
            }
            if line.hasPrefix("@@") {
                var body = [line]
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("@@") || l.hasPrefix("diff --git") { break }
                    body.append(l)
                    i += 1
                }
                let matches =
                    body[0] == hunk.header
                    || body[0].hasPrefix("@@ -\(hunk.oldStart)")
                if matches {
                    var out = header
                    if out.isEmpty {
                        return GitPatchBuilder.makePatch(path: path, hunk: hunk)
                    }
                    out.append(contentsOf: body)
                    return out.joined(separator: "\n") + "\n"
                }
                continue
            }
            i += 1
        }
        return nil
    }

    private func applyPatch(_ patch: String, cached: Bool, reverse: Bool) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("patch-\(UUID().uuidString).diff")
        try patch.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // SCM-N07: git apply --check before mutation.
        var checkArgs = ["apply", "--check"]
        if cached { checkArgs.append("--cached") }
        if reverse { checkArgs.append("--reverse") }
        checkArgs.append("--unidiff-zero")
        checkArgs.append(tmp.path)
        do {
            _ = try await runString(checkArgs)
        } catch let error as SCMError {
            if case .failed(let msg) = error {
                throw SCMError.patchCheckFailed(SCMLogSanitizer.sanitize(msg))
            }
            throw SCMError.patchCheckFailed(SCMLogSanitizer.sanitize(String(describing: error)))
        }

        var applyArgs = ["apply"]
        if cached { applyArgs.append("--cached") }
        if reverse { applyArgs.append("--reverse") }
        applyArgs.append("--unidiff-zero")
        applyArgs.append(tmp.path)
        _ = try await runString(applyArgs)
    }

    private func prepareRemoteAuth(remote: String?) async throws {
        let host = remote ?? "origin"
        if auth != nil {
            let request = SCMAuthRequest(protocolName: "https", host: host, path: "/")
            let creds = try await requireCredentials(for: request)
            try writeAskpassCredentials(creds)
        }
    }

    private func ensureAskpassHelper() throws -> URL {
        if let askpassDir {
            return askpassDir.appendingPathComponent("askpass.sh")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("askpass.sh")
        let body = """
            #!/bin/sh
            # SCM askpass helper — reads credentials from sibling files (mode 0600).
            DIR="$(cd "$(dirname "$0")" && pwd)"
            PROMPT="$1"
            case "$PROMPT" in
              *[Pp]assword*|*[Pp]assphrase*)
                if [ -f "$DIR/password" ]; then cat "$DIR/password"; fi
                ;;
              *)
                if [ -f "$DIR/username" ]; then cat "$DIR/username"; fi
                ;;
            esac
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        askpassDir = dir
        return script
    }

    private func writeAskpassCredentials(_ creds: SCMCredentials) throws {
        let script = try ensureAskpassHelper()
        let dir = script.deletingLastPathComponent()
        if let user = creds.username {
            let url = dir.appendingPathComponent("username")
            try user.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let pass = creds.password {
            let url = dir.appendingPathComponent("password")
            try pass.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func runString(
        _ arguments: [String],
        remoteHost: String? = nil
    ) async throws -> String {
        let data = try await runData(arguments, remoteHost: remoteHost)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func runData(
        _ arguments: [String],
        remoteHost: String? = nil
    ) async throws -> Data {
        try platformProfile.requireLocal(.localGitCLI)
        try requireTrusted()

        if cancelRequested {
            throw CancellationError()
        }

        var env: [String: String] = [
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        if let remoteHost {
            let remoteEnv = await gitEnvironmentForRemote(host: remoteHost)
            env.merge(remoteEnv) { _, new in new }
        }

        let request = ProcessLaunchRequest(
            executable: executable.path,
            arguments: arguments,
            mode: .direct,
            currentDirectory: repositoryRoot,
            environment: env,
            mergeEnvironment: true,
            timeout: .seconds(120),
            maxStdoutBytes: maxStdoutBytes,
            maxStderrBytes: maxStderrBytes,
            capabilityKind: .localGitCLI
        )

        let handle = try await supervisor.spawn(request)
        lastSpawnMaxStdoutBytes = maxStdoutBytes
        lastSpawnMaxStderrBytes = maxStderrBytes
        lastSpawnUsedProcessSupervisor = true
        activeHandles[handle.id] = handle
        defer { activeHandles[handle.id] = nil }

        // Apply cancel that raced ahead of spawn registration (SCM-N03).
        if cancelRequested {
            handle.requestCancellation(escalation: .termThenKill())
        }

        var out = Data()
        var err = Data()
        var code: Int32 = -1
        var overflow: SCMError?
        var sawExit = false

        for await event in handle.events {
            if cancelRequested {
                handle.requestCancellation(escalation: .termThenKill())
            }
            switch event {
            case .stdout(let d):
                out.append(d)
            case .stderr(let d):
                err.append(d)
                if let text = String(data: d, encoding: .utf8), !text.isEmpty {
                    let sanitized = SCMLogSanitizer.sanitize(text)
                    for line in sanitized.split(separator: "\n") where !line.isEmpty {
                        let s = String(line)
                        await progressHub.publish(.message(s))
                        if let frac = Self.parseGitProgressFraction(s) {
                            await progressHub.publish(.fraction(frac))
                        }
                    }
                }
            case .outputGap(let stream, let dropped):
                overflow = .outputOverflow(
                    stream: stream == .stdout ? "stdout" : "stderr",
                    droppedBytes: dropped
                )
            case .exited(let c, let timedOut):
                sawExit = true
                if timedOut { throw SCMError.failed("timeout") }
                code = c
            }
        }

        if cancelRequested {
            throw CancellationError()
        }
        if let overflow {
            throw overflow
        }
        if out.count >= maxStdoutBytes {
            throw SCMError.outputOverflow(stream: "stdout", droppedBytes: 0)
        }

        if !sawExit {
            if cancelRequested { throw CancellationError() }
            throw SCMError.failed("process ended without exit event")
        }

        if code != 0 {
            if cancelRequested {
                throw CancellationError()
            }
            let e = String(data: err, encoding: .utf8) ?? String(decoding: err, as: UTF8.self)
            let sanitized = SCMLogSanitizer.sanitize(e)
            if sanitized.lowercased().contains("not a git repository") {
                throw SCMError.notARepository
            }
            if sanitized.lowercased().contains("authentication")
                || sanitized.lowercased().contains("could not read username")
            {
                throw SCMError.authFailed(sanitized.isEmpty ? "authentication failed" : sanitized)
            }
            throw SCMError.failed(sanitized.isEmpty ? "git exit \(code)" : sanitized)
        }
        return out
    }
}
