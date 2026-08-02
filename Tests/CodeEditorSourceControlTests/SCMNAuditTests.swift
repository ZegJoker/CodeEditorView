import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation
import Testing

@testable import CodeEditorSourceControl

@Suite("SCM-N audit remediation")
struct SCMNAuditTests {

    // MARK: - Helpers

    private static var gitExecutable: URL? {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        return FileManager.default.isExecutableFile(atPath: git.path) ? git : nil
    }

    private func makeTempRepo(named prefix: String = "scm-n") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func runGit(_ args: [String], in root: URL) throws {
        guard let git = Self.gitExecutable else {
            Issue.record("git executable missing at /usr/bin/git")
            throw SCMError.failed("git missing")
        }
        let p = Process()
        p.executableURL = git
        p.arguments = args
        p.currentDirectoryURL = root
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        if p.terminationStatus != 0 {
            throw SCMError.failed("git \(args.joined(separator: " ")) exit \(p.terminationStatus)")
        }
    }

    private func initRepo(_ root: URL) throws {
        #expect(Self.gitExecutable != nil, "git required at /usr/bin/git")
        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "scm-n@example.com"], in: root)
        try runGit(["config", "user.name", "SCM N"], in: root)
        try runGit(["config", "commit.gpgsign", "false"], in: root)
    }

    // MARK: - SCM-N01 repository identity

    @Test func test_SCM_N01_providerIdentityIsPerRepositoryNotConstantGit() async throws {
        let a = try makeTempRepo(named: "id-a")
        let b = try makeTempRepo(named: "id-b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let pa = GitCLIProvider(repositoryRoot: a, trusted: true)
        let pb = GitCLIProvider(repositoryRoot: b, trusted: true)
        let idA = await pa.id
        let idB = await pb.id
        #expect(idA != "git", "constant provider id collides across repositories")
        #expect(idB != "git")
        #expect(idA != idB)
        #expect(idA.hasPrefix("git:"))
        #expect(idB.hasPrefix("git:"))
        #expect(await pa.repositoryIdentity.rawValue == idA)
        #expect(await pb.repositoryIdentity.rawValue == idB)
    }

    @Test func test_SCM_N01_identityUsesCanonicalResolvedRoot() async throws {
        let root = try makeTempRepo(named: "id-canon")
        defer { try? FileManager.default.removeItem(at: root) }
        let viaDots = root.appendingPathComponent("sub/..", isDirectory: true)
        let p1 = GitCLIProvider(repositoryRoot: root, trusted: true)
        let p2 = GitCLIProvider(repositoryRoot: viaDots, trusted: true)
        let id1 = await p1.repositoryIdentity
        let id2 = await p2.repositoryIdentity
        #expect(id1 == id2, "identity must canonicalize path text, not only raw string")
    }

    @Test func test_SCM_N01_serviceRegistersDistinctProvidersWithoutCollision() async throws {
        let a = try makeTempRepo(named: "svc-a")
        let b = try makeTempRepo(named: "svc-b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let service = SourceControlService()
        await service.setTrusted(true)
        await service.registerProvider(GitCLIProvider(repositoryRoot: a, trusted: true))
        await service.registerProvider(GitCLIProvider(repositoryRoot: b, trusted: true))
        let ids = await service.allProviderIDs()
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(!ids.contains("git"))
    }

    // MARK: - SCM-N02 auth callback

    @Test func test_SCM_N02_authCallbackIsInvokedForRemoteAuthPrompt() async throws {
        actor CaptureAuth: SCMAuthCallback {
            private var _calls: [SCMAuthRequest] = []
            func credentials(for request: SCMAuthRequest) async -> SCMCredentials? {
                _calls.append(request)
                return SCMCredentials(username: "user", password: "s3cret-token")
            }
            func callCount() -> Int { _calls.count }
            func firstHost() -> String? { _calls.first?.host }
        }
        let auth = CaptureAuth()
        let root = try makeTempRepo(named: "auth")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true, auth: auth)

        // Remote path must resolve credentials and wire GIT_ASKPASS before git spawn (not only direct resolve).
        let env = await provider.gitEnvironmentForRemote(host: "example.com")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        guard let askpass = env["GIT_ASKPASS"], !askpass.isEmpty else {
            Issue.record("GIT_ASKPASS must be set when auth callback is configured")
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: askpass))
        #expect(env["GIT_ASKPASS_REQUIRE"] == "force")

        // fetch/pull path invokes auth callback and writes askpass material before spawning git.
        do {
            try await provider.fetch(remote: "origin")
        } catch {
            // Remote may not exist — auth + askpass wiring still required.
        }
        #expect(await auth.callCount() >= 1)
        let host = await auth.firstHost()
        #expect(host == "origin" || host == "example.com")

        // Runtime: git-compatible askpass helper returns password when prompted.
        let passwordFile = URL(fileURLWithPath: askpass).deletingLastPathComponent()
            .appendingPathComponent("password")
        #expect(FileManager.default.fileExists(atPath: passwordFile.path))
        let ask = Process()
        ask.executableURL = URL(fileURLWithPath: askpass)
        ask.arguments = ["Password for 'https://example.com':"]
        let out = Pipe()
        ask.standardOutput = out
        try ask.run()
        ask.waitUntilExit()
        let got = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(got.contains("s3cret-token"))
    }

    @Test func test_SCM_N02_missingAuthFailsClosedWithoutTerminalPrompt() async throws {
        let root = try makeTempRepo(named: "auth-miss")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true, auth: nil)
        let env = await provider.gitEnvironmentForRemote(host: "github.com")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        // No askpass wiring when auth is nil — fail closed (no interactive prompt).
        #expect(env["GIT_ASKPASS"] == nil || env["GIT_ASKPASS"]?.isEmpty == true)
        do {
            _ = try await provider.requireCredentials(
                for: SCMAuthRequest(protocolName: "https", host: "github.com", path: "/x.git")
            )
            Issue.record("expected authRequired when no callback")
        } catch let error as SCMError {
            #expect(error == .authRequired)
        }
    }

    @Test func test_SCM_N02_errorsAndLogsNeverExposeSecrets() async throws {
        let sanitized = SCMLogSanitizer.sanitize(
            "fatal: Authentication failed for user pass=s3cret-token Authorization: Bearer abc.def"
        )
        #expect(!sanitized.contains("s3cret-token"))
        #expect(!sanitized.contains("Bearer abc.def"))
        #expect(sanitized.contains("***") || sanitized.lowercased().contains("redacted"))
    }

    // MARK: - SCM-N03 progress path

    @Test func test_SCM_N03_longOperationEmitsProgressAndSupportsCancel() async throws {
        let root = try makeTempRepo(named: "prog")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Slow stand-in for a long git network op so cancel is observable.
        let sleeper = root.appendingPathComponent("slow-git.sh")
        try """
            #!/bin/sh
            sleep 30
            exit 0
            """.write(to: sleeper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sleeper.path)

        let provider = GitCLIProvider(
            repositoryRoot: root,
            executable: sleeper,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean
        )

        async let collector: [SCMProgressEvent] = {
            var events: [SCMProgressEvent] = []
            for await item in await provider.makeProgressStream(replay: .allBuffered) {
                switch item {
                case .value(let env):
                    events.append(env.event)
                    if case .cancelled = env.event { return events }
                    if case .finished = env.event { return events }
                case .finished:
                    return events
                case .gap:
                    break
                }
            }
            return events
        }()

        let op = Task<Void, Never> {
            do {
                _ = try await provider.status()
                Issue.record("expected cancellation before status completed")
            } catch let error as SCMError {
                #expect(error == .cancelled)
            } catch {
                // CancellationError or process failure after cancel
            }
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        await provider.cancel()
        await op.value
        try await Task.sleep(nanoseconds: 50_000_000)
        await provider.finishProgressStreamForTests()
        let events = await collector

        #expect(events.contains { if case .started(let op, _) = $0 { return op == "status" }; return false })
        #expect(
            events.contains { if case .cancelled(let op) = $0 { return op == "status" }; return false }
                || events.contains { if case .finished(let op, let ok) = $0 { return op == "status" && !ok }; return false },
            "cancel must emit cancelled (or failed finished) progress"
        )
        #expect(events.contains { if case .fraction = $0 { return true }; return false }, "must publish fraction progress")
    }

    @Test func test_SCM_N03_parsesGitProgressFractionAndPublishes() async throws {
        #expect(GitCLIProvider.parseGitProgressFraction("Receiving objects:  45% (123/456)") == 0.45)
        #expect(GitCLIProvider.parseGitProgressFraction("Resolving deltas: 100% (10/10), done.") == 1.0)
        #expect(GitCLIProvider.parseGitProgressFraction("no percent here") == nil)

        let root = try makeTempRepo(named: "prog-frac")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        #expect(Self.gitExecutable != nil, "git required for progress fraction integration")

        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean
        )
        async let collector: [SCMProgressEvent] = {
            var events: [SCMProgressEvent] = []
            for await item in await provider.makeProgressStream(replay: .allBuffered) {
                switch item {
                case .value(let env):
                    events.append(env.event)
                    if case .finished = env.event { return events }
                case .finished:
                    return events
                case .gap:
                    break
                }
            }
            return events
        }()
        _ = try await provider.status()
        try await Task.sleep(nanoseconds: 30_000_000)
        await provider.finishProgressStreamForTests()
        let events = await collector
        #expect(events.contains { if case .fraction(let f) = $0 { return f >= 0 && f <= 1 }; return false })
        #expect(events.contains { if case .started = $0 { return true }; return false })
        #expect(events.contains { if case .finished(_, true) = $0 { return true }; return false })
    }

    @Test func test_SCM_N03_oneOperationCoordinatorPerRepository() async throws {
        let root = try makeTempRepo(named: "coord")
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true)
        let gateA = await provider.operationGateID
        let gateB = await provider.operationGateID
        #expect(gateA == gateB, "single coordinator per repository instance")
    }

    // MARK: - SCM-N04 dual index/worktree status

    @Test func test_SCM_N04_statusRepresentsIndexAndWorktreeSimultaneously() {
        let root = URL(fileURLWithPath: "/repo")
        // MM = modified in index AND worktree
        var data = Data("MM both.swift".utf8)
        data.append(0)
        // M  = staged only
        data.append(contentsOf: "M  staged.swift".utf8)
        data.append(0)
        //  M = worktree only
        data.append(contentsOf: " M unstaged.swift".utf8)
        data.append(0)
        // AM = added in index, modified in worktree
        data.append(contentsOf: "AM added-mod.swift".utf8)
        data.append(0)
        // UA unmerged
        data.append(contentsOf: "UU conflict.swift".utf8)
        data.append(0)
        // intent-to-add: A  with special? Actually "A " is added; intent-to-add is rare (git add -N → " A" with index space? Actually intent-to-add is "A " in index with empty blob — porcelain shows "A ")
        // Use "A " for added staged and check intentToAdd from "A " vs worktree for " A" no — git add -N shows "A " with intent.
        // We'll use explicit ignored/untracked:
        data.append(contentsOf: "?? untracked.md".utf8)
        data.append(0)
        data.append(contentsOf: "!! ignored.bin".utf8)
        data.append(0)

        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        let byPath = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })

        let both = byPath["both.swift"]!
        #expect(both.index == .modified)
        #expect(both.worktree == .modified)
        #expect(both.staged == true)
        #expect(both.hasUnstagedChanges)

        let staged = byPath["staged.swift"]!
        #expect(staged.index == .modified)
        #expect(staged.worktree == .unmodified)
        #expect(staged.staged == true)
        #expect(!staged.hasUnstagedChanges)

        let unstaged = byPath["unstaged.swift"]!
        #expect(unstaged.index == .unmodified)
        #expect(unstaged.worktree == .modified)
        #expect(unstaged.staged == false)

        let am = byPath["added-mod.swift"]!
        #expect(am.index == .added)
        #expect(am.worktree == .modified)

        let conflict = byPath["conflict.swift"]!
        #expect(conflict.unmerged)
        #expect(conflict.index == .unmerged || conflict.worktree == .unmerged)

        #expect(byPath["untracked.md"]?.worktree == .untracked || byPath["untracked.md"]?.index == .untracked)
        #expect(byPath["ignored.bin"]?.index == .ignored || byPath["ignored.bin"]?.worktree == .ignored)
    }

    @Test func test_SCM_N04_renameCopySubmoduleAndIntentToAdd() {
        let root = URL(fileURLWithPath: "/repo")
        var data = Data("R  dest.swift".utf8)
        data.append(0)
        data.append(contentsOf: "src.swift".utf8)
        data.append(0)
        data.append(contentsOf: "C  copy.swift".utf8)
        data.append(0)
        data.append(contentsOf: "orig.swift".utf8)
        data.append(0)
        data.append(contentsOf: " S vendor/lib".utf8)
        data.append(0)
        // Intent-to-add: index A, worktree space with intent flag from parser on "A " — we mark intent when X=A and special marker
        // Porcelain for `git add -N`: "A " path
        data.append(contentsOf: "A  intent.swift".utf8)
        data.append(0)

        let statuses = GitPorcelain.parseStatusZ(data, repositoryRoot: root)
        let byPath = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })
        #expect(byPath["dest.swift"]?.index == .renamed)
        #expect(byPath["dest.swift"]?.originalPath == "src.swift")
        #expect(byPath["copy.swift"]?.index == .copied)
        #expect(byPath["copy.swift"]?.originalPath == "orig.swift")
        #expect(byPath["vendor/lib"]?.isSubmodule == true)
        #expect(byPath["intent.swift"]?.index == .added)
    }

    // MARK: - SCM-N05 mutation serialization

    @Test func test_SCM_N05_mutationsAreSerializedPerRepository() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "serial")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("f.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "f.txt"], in: root)
        try runGit(["commit", "-m", "i"], in: root)

        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean
        )
        let uri = DocumentURI(fileURL: file)
        try "two\n".write(to: file, atomically: true, encoding: .utf8)

        // Concurrent mutations must not corrupt; both complete under exclusive gate.
        async let m1: Void = provider.stage(uris: [uri])
        async let m2: Void = {
            try "three\n".write(to: file, atomically: true, encoding: .utf8)
            try await provider.stage(uris: [uri])
        }()
        try await m1
        try await m2
        let status = try await provider.status()
        #expect(status.contains { $0.path == "f.txt" && $0.staged })
        let maxConcurrent = await provider.operationGate.maxConcurrentMutationsObserved
        #expect(maxConcurrent == 1, "mutations must be exclusive; observed \(maxConcurrent)")
    }

    // MARK: - SCM-N06 dirty document coordination

    @Test func test_SCM_N06_discardFailsClosedWhenDirtyBufferOpen() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("doc.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "doc.swift"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8)

        let uri = DocumentURI(fileURL: file)
        let dirtyURI = uri.rawValue
        let coordinator = SCMDocumentCoordinator { _, relativePaths in
            if relativePaths.isEmpty || relativePaths.contains(where: { $0.hasSuffix("doc.swift") }) {
                throw SCMError.dirtyDocuments([dirtyURI])
            }
        }

        let service = SourceControlService()
        await service.setTrusted(true)
        await service.setDocumentCoordinator(coordinator)
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true, documentCoordinator: coordinator)
        await service.registerProvider(provider)

        do {
            try await service.discard(uris: [uri])
            Issue.record("expected dirtyDocuments failure")
        } catch let error as SCMError {
            guard case .dirtyDocuments(let paths) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(paths.contains(where: { $0.contains("doc.swift") || $0 == uri.rawValue }))
        }

        // File must remain dirty on disk (git checkout not applied)
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk.contains("print(2)"))
    }

    @Test func test_SCM_N06_missingCoordinatorFailsClosedOnDestructive() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "no-coord")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("doc.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "doc.swift"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8)

        let service = SourceControlService()
        await service.setTrusted(true)
        // Intentionally no setDocumentCoordinator — must fail closed, not soft-return.
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true)
        await service.registerProvider(provider)
        let uri = DocumentURI(fileURL: file)

        do {
            try await service.discard(uris: [uri])
            Issue.record("expected documentCoordinatorRequired when coordinator unset")
        } catch let error as SCMError {
            #expect(
                error == .documentCoordinatorRequired
                    || { if case .dirtyDocuments = error { return true }; return false }()
            )
        }
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk.contains("print(2)"), "git must not replace path without coordinator")
    }

    @Test func test_SCM_N06_providerDiscardAndDiscardHunkFailClosedWithoutCoordinator() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "prov-no-coord")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("doc.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "doc.swift"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8)

        // Provider-layer destructive ops must not bypass dirty preflight.
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true, documentCoordinator: nil)
        let uri = DocumentURI(fileURL: file)
        do {
            try await provider.discard(uris: [uri])
            Issue.record("provider.discard must fail closed without document coordinator")
        } catch let error as SCMError {
            #expect(error == .documentCoordinatorRequired)
        }
        do {
            let hunk = SCMDiffHunk(
                header: "@@ -1,1 +1,1 @@",
                oldStart: 1,
                oldCount: 1,
                newStart: 1,
                newCount: 1,
                lines: ["-print(1)", "+print(2)"],
                noNewlineAtEndOfFile: false
            )
            try await provider.discardHunk(hunk, uri: uri)
            Issue.record("provider.discardHunk must fail closed without document coordinator")
        } catch let error as SCMError {
            #expect(error == .documentCoordinatorRequired)
        }
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk.contains("print(2)"))
    }

    @Test @MainActor
    func test_SCM_N06_lifecycleBindingDetectsDirtyOpenDocument() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "life-dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("doc.swift")
        try "print(1)\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "doc.swift"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try "print(2)\n".write(to: file, atomically: true, encoding: .utf8)

        let uri = DocumentURI(fileURL: file)
        let lifecycle = DocumentLifecycleCoordinator()
        let doc = TextDocument(uri: uri, text: "print(2)\n")
        _ = try doc.replaceFullContent("print(2)\neditor dirty\n", markDirty: true)
        #expect(doc.isDirty)
        _ = try await lifecycle.openExisting(doc)

        let service = SourceControlService()
        await service.setTrusted(true)
        let binding = SCMDocumentCoordinator.binding(lifecycle)
        await service.setDocumentCoordinator(binding)
        await service.registerProvider(
            GitCLIProvider(repositoryRoot: root, trusted: true, documentCoordinator: binding)
        )

        do {
            try await service.discard(uris: [uri])
            Issue.record("expected dirtyDocuments from lifecycle binding")
        } catch let error as SCMError {
            guard case .dirtyDocuments = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        let disk = try String(contentsOf: file, encoding: .utf8)
        #expect(disk.contains("print(2)"))
    }

    @Test @MainActor
    func test_SCM_N06_checkoutFailsClosedForAnyDirtyRepoDocument() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "co-dirty")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("a.swift")
        try "a\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "a.swift"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try runGit(["branch", "other"], in: root)

        let uri = DocumentURI(fileURL: file)
        let lifecycle = DocumentLifecycleCoordinator()
        let doc = TextDocument(uri: uri, text: "a\n")
        _ = try doc.replaceFullContent("dirty buffer\n", markDirty: true)
        #expect(doc.isDirty)
        _ = try await lifecycle.openExisting(doc)

        let service = SourceControlService()
        await service.setTrusted(true)
        let binding = SCMDocumentCoordinator.binding(lifecycle)
        await service.setDocumentCoordinator(binding)
        await service.registerProvider(
            GitCLIProvider(repositoryRoot: root, trusted: true, documentCoordinator: binding)
        )

        do {
            try await service.checkout(branch: "other")
            Issue.record("expected dirtyDocuments on checkout")
        } catch let error as SCMError {
            guard case .dirtyDocuments = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func test_SCM_N06_servicePropagatesCoordinatorToGitProvider() async throws {
        let root = try makeTempRepo(named: "prop-coord")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SourceControlService()
        let provider = GitCLIProvider(repositoryRoot: root, trusted: true, documentCoordinator: nil)
        await service.registerProvider(provider)
        #expect(await provider.hasDocumentCoordinator == false)
        await service.setDocumentCoordinator(SCMDocumentCoordinator.alwaysClean)
        #expect(await provider.hasDocumentCoordinator == true, "service must wire coordinator into GitCLIProvider")
    }

    // MARK: - SCM-N07 hunk patches

    @Test func test_SCM_N07_patchIncludesNoNewlineAndPassesGitApplyCheck() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "hunk")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("note.txt")
        // No trailing newline in committed version
        let committed = Data("line1\nline2".utf8)
        try committed.write(to: file)
        try runGit(["add", "note.txt"], in: root)
        try runGit(["commit", "-m", "i"], in: root)
        try Data("line1\nline2-changed".utf8).write(to: file)

        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean
        )
        let uri = DocumentURI(fileURL: file)
        let diff = try await provider.diff(uri: uri)
        #expect(!diff.hunks.isEmpty)
        #expect(diff.raw.contains("No newline") || diff.hunks.contains(where: { $0.noNewlineAtEndOfFile }))

        // Stage hunk via git-validated path (apply --check then apply)
        let hunk = diff.hunks[0]
        try await provider.stageHunk(hunk, uri: uri)
        let status = try await provider.status()
        #expect(status.contains { $0.path == "note.txt" && $0.staged })
    }

    @Test func test_SCM_N07_pathWithSpacesIsQuotedInPatch() async throws {
        let path = "hello world.swift"
        let hunk = SCMDiffHunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            lines: ["-old", "+new"],
            noNewlineAtEndOfFile: false
        )
        let patch = GitPatchBuilder.makePatch(path: path, hunk: hunk)
        // Git C-quote is required for paths with spaces — unquoted alone must fail the test.
        #expect(patch.contains("\"a/hello world.swift\""), "diff --git a/ path must be quoted")
        #expect(patch.contains("\"b/hello world.swift\""), "diff --git b/ path must be quoted")
        #expect(patch.contains("@@ -1,1 +1,1 @@"))
        #expect(patch.contains("-old"))
        #expect(patch.contains("+new"))
        #expect(GitPatchBuilder.quotePath("a/hello world.swift").hasPrefix("\""))
    }

    @Test func test_SCM_N07_applyCheckFailureDoesNotMutate() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "bad-patch")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("x.txt")
        try "abc\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "x.txt"], in: root)
        try runGit(["commit", "-m", "i"], in: root)

        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean
        )
        let uri = DocumentURI(fileURL: file)
        let bad = SCMDiffHunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            lines: ["-not-the-content", "+nope"],
            noNewlineAtEndOfFile: false
        )
        do {
            try await provider.stageHunk(bad, uri: uri)
            Issue.record("expected patchCheckFailed")
        } catch let error as SCMError {
            guard case .patchCheckFailed = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        let status = try await provider.status()
        #expect(!status.contains { $0.path == "x.txt" && $0.staged })
    }

    // MARK: - SCM-N08 lifecycle-safe status stream

    @Test func test_SCM_N08_statusStreamIsMulticastWithReplay() async throws {
        let service = SourceControlService()
        await service.setTrusted(true)
        await service.setDocumentCoordinator(SCMDocumentCoordinator.alwaysClean)
        struct Mock: SourceControlProvider {
            let id: String
            let repositoryIdentity: SCMRepositoryIdentity
            init(id: String) {
                self.id = id
                self.repositoryIdentity = SCMRepositoryIdentity(rawValue: id)
            }
            func status() async throws -> [SCMFileStatus] {
                [
                    SCMFileStatus(
                        uri: DocumentURI(rawValue: "file:///r/a.swift"),
                        path: "a.swift",
                        index: .modified,
                        worktree: .unmodified
                    )
                ]
            }
            func branches() async throws -> SCMBranchList { SCMBranchList() }
        }
        await service.registerProvider(Mock(id: "git:/tmp/r1"))

        async let early: [SCMStatusSnapshot] = {
            var snaps: [SCMStatusSnapshot] = []
            for await item in await service.makeStatusStream(replay: .allBuffered) {
                if case .value(let env) = item {
                    snaps.append(env.event)
                    if snaps.count >= 1 { break }
                }
            }
            return snaps
        }()

        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await service.refresh()
        let earlySnaps = await early
        #expect(!earlySnaps.isEmpty)

        // Late subscriber receives replay
        var late: [SCMStatusSnapshot] = []
        for await item in await service.makeStatusStream(replay: .allBuffered) {
            if case .value(let env) = item {
                late.append(env.event)
                break
            }
        }
        #expect(!late.isEmpty)
        #expect(late[0].statuses.contains { $0.path == "a.swift" })
    }

    @Test func test_SCM_N08_providerRemovalFinishesStreamAndMarksStale() async throws {
        let service = SourceControlService()
        await service.setDocumentCoordinator(SCMDocumentCoordinator.alwaysClean)
        struct Mock: SourceControlProvider {
            let id = "git:/tmp/gone"
            var repositoryIdentity: SCMRepositoryIdentity { SCMRepositoryIdentity(rawValue: id) }
            func status() async throws -> [SCMFileStatus] { [] }
            func branches() async throws -> SCMBranchList { SCMBranchList() }
        }
        await service.registerProvider(Mock())
        _ = try await service.refresh()

        var finished = false
        var sawStale = false
        async let watch: Void = {
            for await item in await service.makeStatusStream(replay: .allBuffered) {
                switch item {
                case .value(let env):
                    if env.event.isStale { sawStale = true }
                case .finished:
                    finished = true
                    return
                case .gap:
                    break
                }
            }
        }()

        await service.removeProvider(id: "git:/tmp/gone")
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = await watch
        #expect(finished || sawStale)
        #expect(finished, "stream must finish on provider removal")
    }

    @Test func test_SCM_N08_watcherDrivenDebouncedRefreshMarksStaleThenFresh() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "watch")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let file = root.appendingPathComponent("w.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "w.txt"], in: root)
        try runGit(["commit", "-m", "i"], in: root)

        let service = SourceControlService()
        await service.setTrusted(true)
        await service.setDocumentCoordinator(SCMDocumentCoordinator.alwaysClean)
        await service.registerProvider(
            GitCLIProvider(
                repositoryRoot: root,
                trusted: true,
                documentCoordinator: SCMDocumentCoordinator.alwaysClean
            )
        )
        _ = try await service.refresh()

        // Injectable backend: service must debounce + mark stale then refresh.
        final class InjectWatcher: WorkspaceFileWatchBackend, @unchecked Sendable {
            var handler: (@Sendable (WorkspaceWatchSignal) -> Void)?
            var started = false
            func start(
                rootID: WorkspaceRootID,
                url: URL,
                excludedNames: Set<String>,
                onEvent: @escaping @Sendable (WorkspaceWatchSignal) -> Void
            ) {
                started = true
                handler = onEvent
            }
            func stop(rootID: WorkspaceRootID) { handler = nil }
            func stopAll() { handler = nil }
            func emitChanged(rootID: WorkspaceRootID) { handler?(.changed(rootID: rootID)) }
        }
        let backend = InjectWatcher()
        await service.startStatusWatching(
            root: root,
            debounce: .milliseconds(50),
            backend: backend
        )
        #expect(backend.started)

        actor StreamProbe {
            var sawStale = false
            var sawFreshAfterStale = false
            func note(stale: Bool) {
                if stale {
                    sawStale = true
                } else if sawStale {
                    sawFreshAfterStale = true
                }
            }
            func done() -> Bool { sawStale && sawFreshAfterStale }
            func snapshot() -> (Bool, Bool) { (sawStale, sawFreshAfterStale) }
        }
        let probe = StreamProbe()
        let collectTask = Task {
            for await item in await service.makeStatusStream(replay: .allBuffered) {
                if case .value(let env) = item {
                    await probe.note(stale: env.event.isStale)
                    if await probe.done() { return }
                }
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        // Mutate worktree + fire watcher event (not a manual refresh command).
        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        let rootID = await service.statusWatchRootID
        #expect(rootID != nil)
        backend.emitChanged(rootID: rootID!)

        // Wait for debounced refresh path.
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await probe.done() { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        collectTask.cancel()
        let (stale, fresh) = await probe.snapshot()
        #expect(stale, "watcher change must publish explicit stale state")
        #expect(fresh, "debounced refresh must publish non-stale snapshot")
        await service.stopStatusWatching()
    }

    // MARK: - SCM-N09 bounded process output

    @Test func test_SCM_N09_usesProcessSupervisorAndBoundedOutput() async throws {
        #expect(Self.gitExecutable != nil, "git required for runtime spawn assertion")
        let root = try makeTempRepo(named: "bound")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean,
            maxStdoutBytes: 64 * 1024,
            maxStderrBytes: 8 * 1024
        )
        #expect(await provider.maxStdoutBytes == 64 * 1024)
        #expect(await provider.maxStderrBytes == 8 * 1024)
        #expect(await provider.lastSpawnMaxStdoutBytes == nil)
        _ = try await provider.status()
        // Runtime spawn must record ProcessSupervisor launch bounds (not source-string grep).
        let launched = await provider.lastSpawnMaxStdoutBytes
        #expect(launched == 64 * 1024, "status must spawn via ProcessSupervisor with maxStdoutBytes=\(String(describing: launched))")
        #expect(await provider.lastSpawnMaxStderrBytes == 8 * 1024)
        #expect(await provider.lastSpawnUsedProcessSupervisor == true)
    }

    @Test func test_SCM_N09_outputOverflowFailsClosed() async throws {
        #expect(Self.gitExecutable != nil, "git required")
        let root = try makeTempRepo(named: "overflow")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(root)
        // Create many files so status -z exceeds tiny bound
        for i in 0..<40 {
            let f = root.appendingPathComponent("file-\(i)-with-a-reasonably-long-name.txt")
            try "content-\(i)\n".write(to: f, atomically: true, encoding: .utf8)
        }
        let provider = GitCLIProvider(
            repositoryRoot: root,
            trusted: true,
            documentCoordinator: SCMDocumentCoordinator.alwaysClean,
            maxStdoutBytes: 32,
            maxStderrBytes: 32
        )
        do {
            _ = try await provider.status()
            Issue.record("expected outputOverflow for tiny stdout bound")
        } catch let error as SCMError {
            guard case .outputOverflow = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
    }

    @Test func test_SCM_N09_sanitizedFailureHidesCredentials() {
        let raw = "remote: Invalid username or password: s3cret\nfatal: Authentication failed for 'https://user:s3cret@host/repo'"
        let cleaned = SCMLogSanitizer.sanitize(raw)
        #expect(!cleaned.contains("s3cret"))
        #expect(!cleaned.contains("user:s3cret@"))
    }
}
