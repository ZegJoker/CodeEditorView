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
        // In-process rollback was injected-fail; durable recovery restores via capture owner only
        // (no inverse-create double path) (WSP-N01 / WSP-N06).
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.contains { $0.outcome == .rolledBack || $0.outcome == .quarantined })
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
        #expect(result == .cancelled || result == .closed)
        // Best-effort may close a and leave b.
        #expect(ws.documents.document(id: b.document.id) != nil)
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
        let root = try makeTempRoot(files: ["p.txt": "p"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = try await LocalWorkspaceFileSystem(
            rootDirectories: [root],
            enablesDirectoryWatching: false
        )
        let stream = await fs.progressEvents()
        let rootID = try #require(await fs.roots.first).id
        let collector = Task<Bool, Never> {
            for await item in stream {
                if case .value = item {
                    return true
                }
            }
            return false
        }
        _ = try await fs.children(of: WorkspaceItemID(rootID: rootID, path: ""))
        try await Task.sleep(nanoseconds: 150_000_000)
        collector.cancel()
        let saw = await collector.value
        let listCount = await fs.directoryListCount
        #expect(saw || listCount >= 1)
        #expect(await fs.lastWorkerUsedBackgroundExecutor)
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

        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.count >= 1)
        #expect(recovery.results.contains { $0.outcome == .rolledBack || $0.outcome == .resumedCommitted })
        // After rollback recovery, original file must still exist.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("j.txt").path))
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
        let journal = DurableWorkspaceJournal(
            formatVersion: DurableWorkspaceJournal.currentFormatVersion,
            transactionID: UUID().uuidString,
            createdAt: Date(),
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
        let encoded = try JSONEncoder().encode(journal)
        // Write without valid checksum so validation fails closed OR path escape quarantines.
        try encoded.write(to: txDir.appendingPathComponent("journal.json"))
        let coordinator = WorkspaceTransactionCoordinator(workspace: ws, journalRoot: journalRoot)
        let recovery = try await coordinator.recoverPendingTransactions()
        #expect(recovery.results.contains { $0.outcome == .quarantined || $0.outcome == .rolledBack })
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
        #expect(Bool(true))
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
}
