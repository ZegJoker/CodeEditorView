import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorWorkspace

// MARK: - Helpers

private func makeTempRoot(files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CEWorkspace-WSP-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (relative, contents) in files {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: url)
    }
    return dir
}

@MainActor
private func makeAuditWorkspace(
    files: [String: String] = ["a.txt": "alpha", "b.txt": "beta"],
    settings: WorkspaceSettings = .default
) async throws -> (Workspace, URL) {
    let root = try makeTempRoot(files: files)
    let fs = try await LocalWorkspaceFileSystem(
        rootDirectories: [root],
        settings: settings,
        enablesDirectoryWatching: false
    )
    let ws = Workspace(
        fileSystem: fs,
        documentProvider: LocalFileDocumentProvider(),
        settings: settings,
        dirtyTabClosePolicy: .prompt
    )
    return (ws, root)
}

// MARK: - WSP-N01 transaction coordinator

@Suite("WSP-N01 workspace transaction")
@MainActor
struct WSPN01TransactionTests {
    @Test func test_WSP_N01_failedTransactionLeavesNoUserVisibleUndo() async throws {
        let (ws, root) = try await makeAuditWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = TextDocument(text: "hello")
        try await ws.lifecycle.openExisting(doc)
        #expect(!doc.undo.canUndo)

        let service = WorkspaceEditService(workspace: ws)
        service.faultPoint = .afterFirstDocument
        let second = TextDocument(text: "world")
        try await ws.lifecycle.openExisting(second)

        let edit = WorkspaceEdit(documentChanges: [
            DocumentChange(
                uri: doc.uri,
                documentID: doc.id,
                expectedVersion: doc.version,
                transaction: .single(range: NSRange(location: 0, length: 5), replacement: "HELLO")
            ),
            DocumentChange(
                uri: second.uri,
                documentID: second.id,
                expectedVersion: second.version,
                transaction: .single(range: NSRange(location: 0, length: 5), replacement: "WORLD")
            ),
        ])
        do {
            _ = try await service.apply(edit)
            Issue.record("expected injected fault")
        } catch {
            // expected
        }
        #expect(doc.text == "hello")
        #expect(second.text == "world")
        #expect(!doc.undo.canUndo)
        #expect(!second.undo.canUndo)
        #expect(doc.undo.closedGroupCount == 0)
    }

    @Test func test_WSP_N01_committedEditRegistersSingleUndoPerDocument() async throws {
        let (ws, root) = try await makeAuditWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = TextDocument(text: "hello")
        try await ws.lifecycle.openExisting(doc)
        let service = WorkspaceEditService(workspace: ws)
        let edit = WorkspaceEdit(documentChanges: [
            DocumentChange(
                uri: doc.uri,
                documentID: doc.id,
                expectedVersion: doc.version,
                transaction: .single(range: NSRange(location: 0, length: 5), replacement: "HELLO")
            )
        ])
        _ = try await service.apply(edit)
        #expect(doc.text == "HELLO")
        #expect(doc.undo.canUndo)
        #expect(doc.undo.closedGroupCount == 1)
        try doc.performUndo()
        #expect(doc.text == "hello")
    }

    @Test func test_WSP_N01_oneRollbackOwnerNoDoubleRestore() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["keep.txt": "payload"])
        defer { try? FileManager.default.removeItem(at: root) }
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-rb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }

        let del = DocumentURI(fileURL: root.appendingPathComponent("keep.txt"))
        let service = WorkspaceEditService(workspace: ws, journalRoot: journalRoot)
        service.faultPoint = .duringRollback
        do {
            _ = try await service.apply(WorkspaceEdit(fileOperations: [.delete(uri: del)]))
            Issue.record("expected catastrophic rollback failure")
        } catch let error as WorkspaceEditError {
            switch error {
            case .catastrophic(let original, let rollback):
                #expect(!original.isEmpty)
                #expect(!rollback.isEmpty)
            case .rollbackFailed:
                break
            default:
                Issue.record("expected catastrophic/rollback, got \(error)")
            }
        }
        // Crash-boundary recovery must roll back via the single capture owner (not quarantine).
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.contains { $0.outcome == .rolledBack })
        #expect(!recovery.results.contains { $0.outcome == .quarantined })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep.txt").path))
        let data = try Data(contentsOf: root.appendingPathComponent("keep.txt"))
        #expect(String(data: data, encoding: .utf8) == "payload")
    }

    @Test func test_WSP_N01_prepareCommitUsesLiveIdentity() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["id.txt": "v1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("id.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        let stale = DocumentFileIdentity(
            contentHash: "deadbeef",
            size: 2,
            modificationTime: 1
        )
        let service = WorkspaceEditService(workspace: ws)
        let edit = WorkspaceEdit(documentChanges: [
            DocumentChange(
                uri: uri,
                documentID: opened.document.id,
                expectedVersion: opened.document.version,
                expectedFileIdentity: stale,
                transaction: .single(range: NSRange(location: 0, length: 0), replacement: "x")
            )
        ])
        do {
            _ = try await service.apply(edit)
            Issue.record("expected conflict on stale identity")
        } catch let error as WorkspaceEditError {
            guard case .conflict = error else {
                Issue.record("expected conflict, got \(error)")
                return
            }
        }
        #expect(opened.document.text == "v1")
    }

    @Test func test_WSP_N01_transactionCoordinatorAPI() async throws {
        let (ws, root) = try await makeAuditWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws)
        let doc = TextDocument(text: "z")
        try await ws.lifecycle.openExisting(doc)
        let request = WorkspaceTransactionRequest(
            edit: WorkspaceEdit(documentChanges: [
                DocumentChange(
                    uri: doc.uri,
                    documentID: doc.id,
                    expectedVersion: doc.version,
                    transaction: .single(range: NSRange(location: 0, length: 1), replacement: "Z")
                )
            ])
        )
        let prepared = try await coordinator.prepare(request)
        #expect(prepared.state == .prepared)
        #expect(prepared.transactionID.isEmpty == false)
        let receipt = try await coordinator.commit(prepared)
        #expect(receipt.state == .committed)
        #expect(doc.text == "Z")
    }
}

// MARK: - WSP-N02 delete dirty preflight

@Suite("WSP-N02 dirty delete preflight")
@MainActor
struct WSPN02DeletePreflightTests {
    @Test func test_WSP_N02_deleteAbortsWhenDirtyCancel() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["d.txt": "disk"])
        defer { try? FileManager.default.removeItem(at: root) }
        ws.closeCoordinator.defaultPolicy = .cancel
        let uri = DocumentURI(fileURL: root.appendingPathComponent("d.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "DIRTY")
        )
        let rootID = try #require(await ws.fileSystem.roots.first).id
        let item = WorkspaceItemID(rootID: rootID, path: "d.txt")
        do {
            try await ws.deleteItem(item)
            Issue.record("expected delete aborted")
        } catch let error as WorkspaceError {
            #expect(error == .deleteAborted(reason: "cancelled"))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("d.txt").path))
        #expect(ws.documents.document(id: opened.document.id) != nil)
        #expect(opened.document.isDirty)
    }

    @Test func test_WSP_N02_deleteResolvesDirtyDescendants() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: [
            "dir/nested.txt": "n",
            "dir/other.txt": "o",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        ws.closeCoordinator.defaultPolicy = .discard
        let nestedURI = DocumentURI(fileURL: root.appendingPathComponent("dir/nested.txt"))
        let opened = try await ws.openInActivePane(uri: nestedURI)
        _ = try opened.document.apply(
            .single(range: NSRange(location: 0, length: 0), replacement: "X")
        )
        let rootID = try #require(await ws.fileSystem.roots.first).id
        let dirItem = WorkspaceItemID(rootID: rootID, path: "dir")
        try await ws.deleteItem(dirItem)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("dir").path))
        #expect(ws.documents.document(id: opened.document.id) == nil)
    }

    @Test func test_WSP_N02_deleteStagesThenCommits() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["s.txt": "stage"])
        defer { try? FileManager.default.removeItem(at: root) }
        let rootID = try #require(await ws.fileSystem.roots.first).id
        let item = WorkspaceItemID(rootID: rootID, path: "s.txt")
        try await ws.deleteItem(item)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("s.txt").path))
    }
}

// MARK: - WSP-N03 bulk close atomicity

@Suite("WSP-N03 bulk close phases")
@MainActor
struct WSPN03BulkCloseTests {
    @Test func test_WSP_N03_allOrNothingCancelLeavesEarlierUnsaved() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["a.txt": "a", "b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: root) }

        let delegate = SelectiveCloseDelegate()
        // First dirty → save, second → cancel (decision phase must see both first).
        ws.closeCoordinator.delegate = delegate
        ws.closeCoordinator.defaultPolicy = .prompt
        ws.bulkCloseAtomicity = .allOrNothing

        let a = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("a.txt")))
        let b = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("b.txt")))
        _ = try a.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "A"))
        _ = try b.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "B"))

        delegate.plan = { candidates in
            var map: [DocumentID: CloseDecision] = [:]
            for (i, c) in candidates.enumerated() {
                map[c.documentID] = i == 0 ? .save : .cancel
            }
            return map
        }

        let result = await ws.requestCloseAllTabs()
        #expect(result == .cancelled)
        // All-or-nothing: no document saved or closed when any cancels.
        #expect(a.document.isDirty)
        #expect(b.document.isDirty)
        #expect(ws.panes.values.flatMap(\.tabs).count == 2)
        let diskA = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(diskA == "a")
    }

    @Test func test_WSP_N03_decisionThenSaveThenCommit() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["a.txt": "a", "b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        ws.closeCoordinator.defaultPolicy = .save
        ws.bulkCloseAtomicity = .allOrNothing
        let a = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("a.txt")))
        let b = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("b.txt")))
        _ = try a.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "A"))
        _ = try b.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "B"))
        let result = await ws.requestCloseAllTabs()
        #expect(result == .closed)
        #expect(ws.panes.values.flatMap(\.tabs).isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "A")
        #expect(try String(contentsOf: root.appendingPathComponent("b.txt"), encoding: .utf8) == "B")
    }

    @Test func test_WSP_N03_bestEffortExplicit() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["a.txt": "a", "b.txt": "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        ws.bulkCloseAtomicity = .bestEffort
        let delegate = SelectiveCloseDelegate()
        ws.closeCoordinator.delegate = delegate
        ws.closeCoordinator.defaultPolicy = .prompt
        let a = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("a.txt")))
        let b = try await ws.openInActivePane(uri: DocumentURI(fileURL: root.appendingPathComponent("b.txt")))
        _ = try a.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "A"))
        _ = try b.document.apply(.single(range: NSRange(location: 0, length: 1), replacement: "B"))
        delegate.plan = { candidates in
            Dictionary(uniqueKeysWithValues: candidates.map { c in
                (c.documentID, c.uri.rawValue.hasSuffix("a.txt") ? CloseDecision.discard : CloseDecision.cancel)
            })
        }
        let result = await ws.requestCloseAllTabs()
        // Best-effort: a discarded/closed, b cancelled and still open+dirty, overall cancelled.
        #expect(result == .cancelled)
        #expect(ws.documents.document(id: a.document.id) == nil)
        #expect(ws.documents.document(id: b.document.id) != nil)
        #expect(b.document.isDirty)
        #expect(ws.panes.values.flatMap(\.tabs).contains { $0.documentID == b.document.id })
    }
}

@MainActor
private final class SelectiveCloseDelegate: WorkspaceCloseDelegate, @unchecked Sendable {
    var plan: ([CloseCandidate]) -> [DocumentID: CloseDecision] = { _ in [:] }
    func decideClose(_ documents: [CloseCandidate]) async -> [DocumentID: CloseDecision] {
        plan(documents)
    }
}

// MARK: - WSP-N04 FS workers

@Suite("WSP-N04 background FS workers")
struct WSPN04WorkerTests {
    @Test func test_WSP_N04_childrenStreamBatchesAndCancellation() async throws {
        var files: [String: String] = [:]
        for i in 0..<30 {
            files[String(format: "f%02d.txt", i)] = "x"
        }
        let root = try makeTempRoot(files: files)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = WorkspaceSettings(
            excludedNames: [],
            hiddenFilePolicy: .showAll,
            filesystemLimits: WorkspaceFilesystemLimits(
                maxDepth: 8,
                maxFileCount: 1000,
                maxBytes: 10_000_000,
                batchSize: 10,
                maxElapsed: 30
            )
        )
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            settings: settings,
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        let rootItem = WorkspaceItemID(rootID: rootID, path: "")
        var batches: [[WorkspaceItem]] = []
        for try await batch in fs.childrenBatches(of: rootItem) {
            batches.append(batch)
            if batches.count >= 2 { break }
        }
        #expect(batches.count >= 2)
        #expect(batches[0].count == 10)
        #expect(await fs.lastWorkerUsedBackgroundExecutor)
    }

    @Test func test_WSP_N04_progressHubPublishes() async throws {
        let root = try makeTempRoot(files: ["p.txt": "p", "q.txt": "q"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        // Perform work first; progress hub replays recent events to late subscribers (WSP-N04).
        _ = try await fs.children(of: WorkspaceItemID(rootID: rootID, path: ""))
        #expect(await fs.directoryListCount >= 1)
        #expect(await fs.lastWorkerUsedBackgroundExecutor)

        let stream = await fs.progressEvents()
        var sawListing = false
        var sawValue = false
        for await item in stream {
            if case .value(let envelope) = item {
                sawValue = true
                switch envelope.event {
                case .listingStarted, .listingBatch, .listingFinished:
                    sawListing = true
                default:
                    break
                }
            }
            if sawListing { break }
        }
        #expect(sawValue)
        #expect(sawListing)
    }
}

// MARK: - WSP-N05 archive honesty

@Suite("WSP-N05 archive format")
struct WSPN05ArchiveTests {
    @Test func test_WSP_N05_archivePreservesSymlinkWithoutFollow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try "T".data(using: .utf8)!.write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "target.txt"))

        let archive = try WorkspaceArchive.capture(directory: root)
        #expect(archive.claimsByteExactMetadata == false || archive.supportedEntryKinds.contains(.symlink))
        #expect(archive.entries.contains { $0.kind == .symlink && $0.relativePath == "link" })
        let restoreRoot = root.appendingPathComponent("out", isDirectory: true)
        try WorkspaceArchive.restore(archive, to: restoreRoot)
        let linkURL = restoreRoot.appendingPathComponent("link")
        let values = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        #expect(dest == "target.txt" || dest.hasSuffix("target.txt"))
        #expect(FileManager.default.fileExists(atPath: restoreRoot.appendingPathComponent("target.txt").path))
    }

    @Test func test_WSP_N05_noFalseByteExactClaim() {
        #expect(WorkspaceArchive.Format.claimsFullPOSIXMatrix == false)
        #expect(WorkspaceArchive.Format.supportedKinds.contains(.regularFile))
        #expect(WorkspaceArchive.Format.supportedKinds.contains(.directory))
        #expect(WorkspaceArchive.Format.supportedKinds.contains(.symlink))
    }

    @Test func test_WSP_N05_regularFileRoundTripBytesAndMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arch2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bin.dat")
        let payload = Data([0x00, 0xFF, 0x7F])
        try payload.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let archive = try WorkspaceArchive.capture(directory: root)
        let out = root.appendingPathComponent("restored", isDirectory: true)
        try WorkspaceArchive.restore(archive, to: out)
        let restored = try Data(contentsOf: out.appendingPathComponent("bin.dat"))
        #expect(restored == payload)
        let mode = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("bin.dat").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o755)
    }
}

// MARK: - WSP-N06 journal recovery

@Suite("WSP-N06 journal startup recovery")
@MainActor
struct WSPN06JournalRecoveryTests {
    @Test func test_WSP_N06_checksumStableAcrossEncodeDecode() throws {
        var journal = DurableWorkspaceJournal(
            formatVersion: DurableWorkspaceJournal.currentFormatVersion,
            transactionID: "tx-stable",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123),
            workspaceID: "ws",
            state: .prepared,
            operations: ["delete:file:///tmp/x"],
            backupRelativePaths: ["backup.bin"],
            rootPaths: ["/tmp/root"],
            resourceOwners: [
                RollbackResourceOwner(
                    uri: "file:///tmp/root/x",
                    owner: .captureRestore,
                    relativeBackup: "backup.bin"
                )
            ],
            checksum: ""
        )
        journal.checksum = try DurableWorkspaceJournal.computeChecksum(for: journal)
        let data = try DurableWorkspaceJournal.encodeJournal(journal)
        let decoded = try DurableWorkspaceJournal.decodeJournal(from: data)
        let recomputed = try DurableWorkspaceJournal.computeChecksum(for: decoded)
        #expect(decoded.checksum == journal.checksum)
        #expect(recomputed == journal.checksum)
        // Second encode of the same material must match (canonical sorted keys).
        let again = try DurableWorkspaceJournal.computeChecksum(for: decoded)
        #expect(again == recomputed)
    }

    @Test func test_WSP_N06_recoversPendingDeleteJournal() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["j.txt": "journaled"])
        defer { try? FileManager.default.removeItem(at: root) }
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }

        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let del = DocumentURI(fileURL: root.appendingPathComponent("j.txt"))
        let request = WorkspaceTransactionRequest(
            edit: WorkspaceEdit(fileOperations: [.delete(uri: del)])
        )
        let prepared = try await coordinator.prepare(request)
        // Simulate crash after prepare (journal durable, commit not finished):
        // leave prepared journal on disk without committing.
        #expect(FileManager.default.fileExists(atPath: prepared.journalURL!.path))

        // Verify on-disk checksum is valid before recovery (regression for unstable hashing).
        let onDisk = try Data(contentsOf: prepared.journalURL!)
        let journal = try DurableWorkspaceJournal.decodeJournal(from: onDisk)
        #expect(try DurableWorkspaceJournal.computeChecksum(for: journal) == journal.checksum)

        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.count >= 1)
        #expect(recovery.results.contains { $0.outcome == .rolledBack })
        #expect(!recovery.results.contains { $0.outcome == .quarantined && $0.detail.contains("checksum") })
        // After rollback recovery, original file must still exist (delete never committed).
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("j.txt").path))
        #expect(try String(contentsOf: root.appendingPathComponent("j.txt"), encoding: .utf8) == "journaled")
    }

    @Test func test_WSP_N06_activateRunsStartupRecovery() async throws {
        let root = try makeTempRoot(files: ["act.txt": "alive"])
        defer { try? FileManager.default.removeItem(at: root) }
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-act-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }

        // First workspace: prepare a pending delete journal, then "crash" (drop workspace).
        let fs1 = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let ws1 = Workspace(fileSystem: fs1, journalRoot: journalRoot)
        let del = DocumentURI(fileURL: root.appendingPathComponent("act.txt"))
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws1, journalRoot: journalRoot)
        _ = try await coordinator.prepare(
            WorkspaceTransactionRequest(edit: WorkspaceEdit(fileOperations: [.delete(uri: del)]))
        )
        // Second workspace activation must discover and roll back the unfinished journal.
        let fs2 = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let ws2 = Workspace(fileSystem: fs2, journalRoot: journalRoot)
        let report = try await ws2.activate()
        #expect(report.results.contains { $0.outcome == .rolledBack })
        #expect(ws2.lastRecoveryReport?.results.contains { $0.outcome == .rolledBack } == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("act.txt").path))
    }

    @Test func test_WSP_N06_quarantinesCorruptJournal() async throws {
        let (ws, root) = try await makeAuditWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let badDir = journalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: badDir.appendingPathComponent("journal.json"))

        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.contains { $0.outcome == .quarantined })
        let quarantine = journalRoot.appendingPathComponent("quarantine", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
    }

    @Test func test_WSP_N06_rejectsPathEscapeInJournal() async throws {
        let (ws, root) = try await makeAuditWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let journalRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jr-esc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: journalRoot) }

        let txDir = journalRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: txDir, withIntermediateDirectories: true)
        var journal = DurableWorkspaceJournal(
            formatVersion: DurableWorkspaceJournal.currentFormatVersion,
            transactionID: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workspaceID: ws.id.rawValue.uuidString,
            state: .prepared,
            operations: [],
            backupRelativePaths: [],
            rootPaths: [root.path],
            resourceOwners: [
                RollbackResourceOwner(
                    uri: "file:///etc/passwd",
                    owner: .captureRestore,
                    relativeBackup: nil
                )
            ],
            checksum: ""
        )
        // Valid checksum so recovery reaches path-escape validation (not checksum mismatch).
        journal.checksum = try DurableWorkspaceJournal.computeChecksum(for: journal)
        try DurableWorkspaceJournal.encodeJournal(journal)
            .write(to: txDir.appendingPathComponent("journal.json"), options: .atomic)
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.contains { $0.outcome == .quarantined })
        #expect(recovery.results.contains { $0.detail.contains("path escapes") || $0.detail.contains("passwd") || $0.detail.contains("escape") })
    }
}

// MARK: - WSP-N07 sequenced event stream

@Suite("WSP-N07 workspace event stream")
struct WSPN07EventStreamTests {
    @Test func test_WSP_N07_subscriptionStartsWithSnapshotAndSequence() async throws {
        let root = try makeTempRoot(files: ["e.txt": "e"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let stream = await fs.workspaceEvents()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        guard let first else {
            Issue.record("expected snapshot item")
            return
        }
        switch first {
        case .snapshot(_, let sequence):
            #expect(sequence >= 0)
        default:
            Issue.record("first item must be snapshot, got \(first)")
        }
    }

    @Test func test_WSP_N07_noRegistrationRace() async throws {
        let root = try makeTempRoot(files: [:])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        // Subscribe registers on actor before return — no unstructured Task race (WSP-N07).
        let stream = await fs.workspaceEvents()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        guard case .snapshot = first else {
            Issue.record("expected snapshot first")
            return
        }
        let rootID = try #require(await fs.roots.first).id
        let rootItem = WorkspaceItemID(rootID: rootID, path: "")
        _ = try await fs.createFile(in: rootItem, name: "late.txt", contents: Data("x".utf8))
        let second = await iterator.next()
        guard case .event(let envelope) = second else {
            Issue.record("expected sequenced event after mutation, got \(String(describing: second))")
            return
        }
        #expect(envelope.sequence >= 1)
        if case .added(let item) = envelope.event {
            #expect(item.name == "late.txt")
        } else {
            Issue.record("expected added event")
        }
    }
}

// MARK: - WSP-N08 descriptor-relative no-follow

@Suite("WSP-N08 descriptor relative IO")
struct WSPN08DescriptorIOTests {
    @Test func test_WSP_N08_openatNoFollowRejectsSymlinkEscape() throws {
        #if canImport(Darwin)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString)")
        try "secret".data(using: .utf8)!.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let dirfd = try DescriptorRelativeIO.openDirectory(at: root)
        defer { DescriptorRelativeIO.close(dirfd) }
        #expect(throws: DescriptorRelativeIOError.self) {
            _ = try DescriptorRelativeIO.openAt(
                dirfd: dirfd,
                relativePath: "escape",
                flags: DescriptorRelativeIO.O_RDONLY | DescriptorRelativeIO.O_NOFOLLOW
            )
        }
        #else
        // Non-Darwin: descriptor-relative IO must fail closed (not soft-succeed).
        #expect(throws: DescriptorRelativeIOError.notSupported) {
            _ = try DescriptorRelativeIO.openDirectory(at: URL(fileURLWithPath: "/tmp"))
        }
        #expect(throws: DescriptorRelativeIOError.notSupported) {
            _ = try DescriptorRelativeIO.openAt(
                dirfd: -1,
                relativePath: "escape",
                flags: DescriptorRelativeIO.O_RDONLY | DescriptorRelativeIO.O_NOFOLLOW
            )
        }
        #endif
    }

    @Test func test_WSP_N08_mutationUsesDescriptorRelativePath() async throws {
        let root = try makeTempRoot(files: ["safe.txt": "s"])
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = WorkspaceSettings.default
        settings.pathResolveOptions.useDescriptorRelativeIO = true
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            settings: settings,
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        let item = WorkspaceItemID(rootID: rootID, path: "safe.txt")
        try await fs.delete(item: item)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("safe.txt").path))
        #expect(await fs.lastMutationUsedDescriptorRelativeIO)
    }
}

// MARK: - WSP-N09 hidden file policy

@Suite("WSP-N09 hidden file policy")
struct WSPN09HiddenPolicyTests {
    @Test func test_WSP_N09_showAllListsDotfiles() async throws {
        let root = try makeTempRoot(files: [".gitignore": "node_modules", "a.txt": "a"])
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = WorkspaceSettings(
            excludedNames: [],
            hiddenFilePolicy: .showAll
        )
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            settings: settings,
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        let kids = try await fs.children(of: WorkspaceItemID(rootID: rootID, path: ""))
        #expect(kids.contains { $0.name == ".gitignore" })
        #expect(kids.contains { $0.name == "a.txt" })
    }

    @Test func test_WSP_N09_hideDotfilesPolicy() async throws {
        let root = try makeTempRoot(files: [".hidden": "h", "visible.txt": "v"])
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = WorkspaceSettings(
            excludedNames: [],
            hiddenFilePolicy: .hideDotfiles
        )
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            settings: settings,
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        let kids = try await fs.children(of: WorkspaceItemID(rootID: rootID, path: ""))
        #expect(!kids.contains { $0.name == ".hidden" })
        #expect(kids.contains { $0.name == "visible.txt" })
    }

    @Test func test_WSP_N09_explicitRevealOverridesHide() async throws {
        let root = try makeTempRoot(files: [".env": "x", "a.txt": "a"])
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = WorkspaceSettings(
            excludedNames: [],
            hiddenFilePolicy: .hideDotfiles,
            revealedHiddenNames: [".env"]
        )
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            settings: settings,
            enablesDirectoryWatching: false
        )
        let rootID = try #require(await fs.roots.first).id
        let kids = try await fs.children(of: WorkspaceItemID(rootID: rootID, path: ""))
        #expect(kids.contains { $0.name == ".env" })
    }
}

// MARK: - WSP-N10 lifecycle coordinator sole mutator

@Suite("WSP-N10 document lifecycle coordinator")
@MainActor
struct WSPN10LifecycleTests {
    @Test func test_WSP_N10_openCloseOnlyViaLifecycle() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["lc.txt": "x"])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("lc.txt"))
        let doc = try await ws.openDocument(uri: uri)
        #expect(ws.lifecycle.isRegistered(doc.id))
        #expect(ws.documents.document(id: doc.id) != nil)

        try await ws.lifecycle.close(documentID: doc.id, reason: .explicit)
        #expect(ws.documents.document(id: doc.id) == nil)
        #expect(!ws.lifecycle.isRegistered(doc.id))
    }

    @Test func test_WSP_N10_workspaceOpenUsesLifecycle() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["w.txt": "w"])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("w.txt"))
        _ = try await ws.openInActivePane(uri: uri)
        #expect(ws.lifecycle.registeredCount == 1)
    }

    @Test func test_WSP_N10_finalLeaseReleaseRoutesThroughLifecycle() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["f.txt": "f"])
        defer { try? FileManager.default.removeItem(at: root) }
        ws.closeCoordinator.defaultPolicy = .discard
        let uri = DocumentURI(fileURL: root.appendingPathComponent("f.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        let paneID = try #require(ws.activePaneID)
        let result = await ws.requestCloseTab(opened.tab.id, in: paneID)
        #expect(result == .closed)
        #expect(ws.documents.document(id: opened.document.id) == nil)
        #expect(ws.lifecycle.registeredCount == 0)
    }

    @Test func test_WSP_N10_renameRoutesThroughLifecycle() async throws {
        let (ws, root) = try await makeAuditWorkspace(files: ["old.txt": "o"])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("old.txt"))
        let opened = try await ws.openInActivePane(uri: uri)
        let rootID = try #require(await ws.fileSystem.roots.first).id
        let item = WorkspaceItemID(rootID: rootID, path: "old.txt")
        _ = try await ws.renameItem(item, to: "new.txt")
        #expect(opened.document.uri.fileURL?.lastPathComponent == "new.txt")
        #expect(ws.documents.document(uri: DocumentURI(fileURL: root.appendingPathComponent("new.txt"))) != nil)
    }

    @Test func test_WSP_N10_registryMutationIsPackageScoped() async throws {
        // WSP-N10: DocumentRegistry.register/remove are package-scoped; public surface is
        // read-only. Sole production mutator is DocumentLifecycleCoordinator.
        let (ws, root) = try await makeAuditWorkspace(files: ["m.txt": "m"])
        defer { try? FileManager.default.removeItem(at: root) }
        let uri = DocumentURI(fileURL: root.appendingPathComponent("m.txt"))
        let doc = try await ws.lifecycle.open(uri: uri, provider: LocalFileDocumentProvider())
        #expect(ws.lifecycle.isRegistered(doc.id))
        #expect(ws.documents.document(id: doc.id) != nil)
        // Closing only via lifecycle drops registry entry.
        try await ws.lifecycle.close(documentID: doc.id, reason: .explicit)
        #expect(ws.documents.document(id: doc.id) == nil)
        // Source contract: Workspace.swift documents comment + package access on registry
        // mutation methods (verified by building consumers outside package fails on remove).
        let sources = [
            "Sources/CodeEditorDocuments/DocumentRegistry.swift",
            "Sources/CodeEditorWorkspace/DocumentLifecycleCoordinator.swift",
        ]
        let cwd = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for rel in sources {
            let text = try String(contentsOf: cwd.appendingPathComponent(rel), encoding: .utf8)
            if rel.contains("DocumentRegistry") {
                #expect(text.contains("package func register"))
                #expect(text.contains("package func remove"))
            }
            if rel.contains("DocumentLifecycleCoordinator") {
                #expect(text.contains("registry.register") || text.contains("registry.remove"))
                #expect(text.contains("Sole owner") || text.contains("sole"))
            }
        }
    }
}
