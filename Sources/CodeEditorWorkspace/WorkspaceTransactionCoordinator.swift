import CodeEditorCore
import CodeEditorDocuments
import CryptoKit
import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Journal / transaction types (WSP-N01 / WSP-N06)

/// Explicit durable journal state machine (WSP-N01).
public enum WorkspaceTransactionState: String, Sendable, Hashable, Codable {
    case preparing
    case prepared
    case committing
    case committed
    case rollingBack
    case rolledBack
    case recoveryRequired
}

/// Which mechanism owns rollback for a resource (exactly one) (WSP-N01).
public enum RollbackOwnerKind: String, Sendable, Hashable, Codable {
    /// Restore from captured archive/bytes only.
    case captureRestore
    /// Inverse of a create (delete the created path).
    case inverseCreate
    /// Document content inverse only.
    case documentInverse
}

public struct RollbackResourceOwner: Codable, Sendable, Hashable {
    public var uri: String
    public var owner: RollbackOwnerKind
    public var relativeBackup: String?

    public init(uri: String, owner: RollbackOwnerKind, relativeBackup: String? = nil) {
        self.uri = uri
        self.owner = owner
        self.relativeBackup = relativeBackup
    }
}

/// Durable journal payload with checksum (WSP-N06).
public struct DurableWorkspaceJournal: Codable, Sendable, Hashable {
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var transactionID: String
    public var createdAt: Date
    public var workspaceID: String
    public var state: WorkspaceTransactionState
    public var operations: [String]
    public var backupRelativePaths: [String]
    public var rootPaths: [String]
    public var resourceOwners: [RollbackResourceOwner]
    /// Hex SHA-256 of canonical payload excluding this field.
    public var checksum: String

    public init(
        formatVersion: Int = currentFormatVersion,
        transactionID: String,
        createdAt: Date,
        workspaceID: String,
        state: WorkspaceTransactionState,
        operations: [String],
        backupRelativePaths: [String],
        rootPaths: [String],
        resourceOwners: [RollbackResourceOwner],
        checksum: String
    ) {
        self.formatVersion = formatVersion
        self.transactionID = transactionID
        self.createdAt = createdAt
        self.workspaceID = workspaceID
        self.state = state
        self.operations = operations
        self.backupRelativePaths = backupRelativePaths
        self.rootPaths = rootPaths
        self.resourceOwners = resourceOwners
        self.checksum = checksum
    }

    /// Canonical JSON encoder for checksum material (stable key order + integer ms dates).
    /// Using unsorted `JSONEncoder` key order is non-deterministic across encode calls and
    /// makes encode→decode→recompute always fail-closed on valid journals (WSP-N06).
    public static func makeCanonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static func makeCanonicalDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public static func computeChecksum(for journal: DurableWorkspaceJournal) throws -> String {
        var copy = journal
        copy.checksum = ""
        let data = try makeCanonicalEncoder().encode(copy)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func encodeJournal(_ journal: DurableWorkspaceJournal) throws -> Data {
        try makeCanonicalEncoder().encode(journal)
    }

    public static func decodeJournal(from data: Data) throws -> DurableWorkspaceJournal {
        try makeCanonicalDecoder().decode(DurableWorkspaceJournal.self, from: data)
    }
}

public struct WorkspaceTransactionRequest: Sendable {
    public var edit: WorkspaceEdit
    public var revalidateIdentities: Bool

    public init(edit: WorkspaceEdit, revalidateIdentities: Bool = true) {
        self.edit = edit
        self.revalidateIdentities = revalidateIdentities
    }
}

public struct PreparedCapture: Sendable {
    public var uri: DocumentURI
    public var isDirectory: Bool
    public var owner: RollbackOwnerKind
    public var backupFileName: String?
    public var archive: WorkspaceArchive?
    public var fileBytes: Data?
    public var posixPermissions: NSNumber?
    public var modificationDate: Date?

    public init(
        uri: DocumentURI,
        isDirectory: Bool,
        owner: RollbackOwnerKind,
        backupFileName: String? = nil,
        archive: WorkspaceArchive? = nil,
        fileBytes: Data? = nil,
        posixPermissions: NSNumber? = nil,
        modificationDate: Date? = nil
    ) {
        self.uri = uri
        self.isDirectory = isDirectory
        self.owner = owner
        self.backupFileName = backupFileName
        self.archive = archive
        self.fileBytes = fileBytes
        self.posixPermissions = posixPermissions
        self.modificationDate = modificationDate
    }
}

public struct PreparedWorkspaceTransaction: Sendable {
    public var transactionID: String
    public var state: WorkspaceTransactionState
    public var request: WorkspaceTransactionRequest
    public var journalURL: URL?
    public var journalDirectory: URL?
    public var resourceOwners: [RollbackResourceOwner]
    public var undoCheckpoints: [DocumentID: Int]
    public var captures: [PreparedCapture]
    public var expectedDocumentVersions: [DocumentID: DocumentVersion]
    public var expectedFileIdentities: [DocumentURI: DocumentFileIdentity]

    public init(
        transactionID: String,
        state: WorkspaceTransactionState,
        request: WorkspaceTransactionRequest,
        journalURL: URL?,
        journalDirectory: URL?,
        resourceOwners: [RollbackResourceOwner],
        undoCheckpoints: [DocumentID: Int],
        captures: [PreparedCapture],
        expectedDocumentVersions: [DocumentID: DocumentVersion],
        expectedFileIdentities: [DocumentURI: DocumentFileIdentity]
    ) {
        self.transactionID = transactionID
        self.state = state
        self.request = request
        self.journalURL = journalURL
        self.journalDirectory = journalDirectory
        self.resourceOwners = resourceOwners
        self.undoCheckpoints = undoCheckpoints
        self.captures = captures
        self.expectedDocumentVersions = expectedDocumentVersions
        self.expectedFileIdentities = expectedFileIdentities
    }
}

public struct WorkspaceTransactionReceipt: Sendable {
    public var transactionID: String
    public var state: WorkspaceTransactionState
    public var result: WorkspaceEditResult?

    public init(transactionID: String, state: WorkspaceTransactionState, result: WorkspaceEditResult? = nil) {
        self.transactionID = transactionID
        self.state = state
        self.result = result
    }
}

public enum WorkspaceRecoveryOutcome: String, Sendable, Hashable, Codable {
    case rolledBack
    case resumedCommitted
    case quarantined
    case skippedClean
}

public struct WorkspaceRecoveryItem: Sendable, Hashable {
    public var transactionID: String
    public var outcome: WorkspaceRecoveryOutcome
    public var detail: String

    public init(transactionID: String, outcome: WorkspaceRecoveryOutcome, detail: String) {
        self.transactionID = transactionID
        self.outcome = outcome
        self.detail = detail
    }
}

public struct WorkspaceRecoveryReport: Sendable {
    public var results: [WorkspaceRecoveryItem]
    public init(results: [WorkspaceRecoveryItem]) { self.results = results }
}

public enum WorkspaceTransactionError: Error, Sendable, Equatable {
    case invalidState(String)
    case validationFailed(String)
    case conflict(String)
    case journalCorrupt(String)
    case pathEscape(String)
    case rollbackFailed(original: String, rollback: String)
    case catastrophic(original: String, rollback: String)
}

// MARK: - Coordinator

/// Two-phase prepare/commit/recover transaction coordinator (WSP-N01 / WSP-N06).
@MainActor
public final class WorkspaceTransactionCoordinator {
    private let workspace: Workspace
    public var journalRoot: URL?
    public var faultPoint: WorkspaceEditFaultPoint?

    public init(workspace: Workspace, journalRoot: URL? = nil) {
        self.workspace = workspace
        self.journalRoot = journalRoot
    }

    /// Preflight + capture + durable journal (state → prepared).
    public func prepare(_ request: WorkspaceTransactionRequest) async throws -> PreparedWorkspaceTransaction {
        let edit = request.edit
        guard !edit.documentChanges.isEmpty || !edit.fileOperations.isEmpty else {
            throw WorkspaceTransactionError.validationFailed("empty workspace edit")
        }

        var undoCheckpoints: [DocumentID: Int] = [:]
        var expectedVersions: [DocumentID: DocumentVersion] = [:]
        var expectedIdentities: [DocumentURI: DocumentFileIdentity] = [:]
        var seenDocURIs = Set<String>()

        for change in edit.documentChanges {
            let key = change.uri.canonicalized().rawValue
            if !seenDocURIs.insert(key).inserted {
                throw WorkspaceTransactionError.validationFailed("duplicate document change: \(change.uri.rawValue)")
            }
            guard let doc = resolveDocument(change) else {
                throw WorkspaceTransactionError.validationFailed("document not found: \(change.uri.rawValue)")
            }
            if let expected = change.expectedVersion, doc.version != expected {
                throw WorkspaceEditError.versionMismatch(
                    uri: change.uri.rawValue,
                    expected: expected.rawValue,
                    actual: doc.version.rawValue
                )
            }
            if request.revalidateIdentities, let expectedID = change.expectedFileIdentity {
                let live = try await liveFileIdentity(for: change.uri) ?? doc.fileIdentity
                if let live, live.contentHash != expectedID.contentHash {
                    throw WorkspaceEditError.conflict(uri: change.uri.rawValue)
                }
                expectedIdentities[change.uri] = expectedID
            }
            undoCheckpoints[doc.id] = doc.undo.closedGroupCount
            expectedVersions[doc.id] = doc.version
            for c in change.transaction.changes {
                _ = try TextOffsetSemantics.validatedUTF16Range(
                    c.replacedRange.nsRange,
                    documentUTF16Length: doc.length
                )
            }
        }

        var touched = Set<String>()
        var captures: [PreparedCapture] = []
        var owners: [RollbackResourceOwner] = []

        for op in edit.fileOperations {
            try await preflightFileOperation(op, touched: &touched)
            switch op {
            case .createFile(let uri, _), .createFileBytes(let uri, _), .createDirectory(let uri):
                owners.append(RollbackResourceOwner(uri: uri.rawValue, owner: .inverseCreate))
            case .delete(let uri), .rename(let uri, _):
                if let cap = try captureExisting(uri: uri) {
                    captures.append(cap)
                    owners.append(
                        RollbackResourceOwner(
                            uri: uri.rawValue,
                            owner: .captureRestore,
                            relativeBackup: cap.backupFileName
                        )
                    )
                }
            }
        }

        for change in edit.documentChanges {
            owners.append(RollbackResourceOwner(uri: change.uri.rawValue, owner: .documentInverse))
        }

        let txID = UUID().uuidString
        var journalURL: URL?
        var journalDir: URL?

        if !edit.fileOperations.isEmpty {
            let roots = await workspace.fileSystem.roots.compactMap { $0.uri.fileURL?.path }
            let written = try writeDurableJournal(
                transactionID: txID,
                state: .prepared,
                operations: edit.fileOperations,
                captures: &captures,
                owners: owners,
                rootPaths: roots
            )
            journalURL = written.journalURL
            journalDir = written.directory
            try? fsyncParent(of: written.journalURL)
        }

        return PreparedWorkspaceTransaction(
            transactionID: txID,
            state: .prepared,
            request: request,
            journalURL: journalURL,
            journalDirectory: journalDir,
            resourceOwners: owners,
            undoCheckpoints: undoCheckpoints,
            captures: captures,
            expectedDocumentVersions: expectedVersions,
            expectedFileIdentities: expectedIdentities
        )
    }

    /// Commit a prepared transaction. Document undo is registered only on success (WSP-N01).
    public func commit(_ prepared: PreparedWorkspaceTransaction) async throws -> WorkspaceTransactionReceipt {
        guard prepared.state == .prepared else {
            throw WorkspaceTransactionError.invalidState("commit requires prepared, got \(prepared.state)")
        }
        try await updateJournalState(prepared, state: .committing)

        let edit = prepared.request.edit
        var applied: [AppliedEditTransaction] = []
        var inverseDocs: [DocumentChange] = []
        var completedOps: [WorkspaceFileOperation] = []
        var createdURIs: [DocumentURI] = []

        do {
            if prepared.request.revalidateIdentities {
                for change in edit.documentChanges {
                    if let expectedID = change.expectedFileIdentity {
                        let live = try await liveFileIdentity(for: change.uri)
                        if let live, live.contentHash != expectedID.contentHash {
                            throw WorkspaceEditError.conflict(uri: change.uri.rawValue)
                        }
                    }
                    if let expected = change.expectedVersion, let doc = resolveDocument(change),
                        doc.version != expected
                    {
                        throw WorkspaceEditError.versionMismatch(
                            uri: change.uri.rawValue,
                            expected: expected.rawValue,
                            actual: doc.version.rawValue
                        )
                    }
                }
            }

            for (index, change) in edit.documentChanges.enumerated() {
                guard let doc = resolveDocument(change) else {
                    throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
                }
                let result = try doc.apply(
                    change.transaction,
                    registerUndo: false,
                    expectedVersion: change.expectedVersion
                )
                applied.append(result)
                inverseDocs.append(
                    DocumentChange(
                        uri: change.uri,
                        documentID: doc.id,
                        expectedVersion: result.newVersion,
                        transaction: result.inverse
                    )
                )
                workspace.promotePreviewTabs(for: doc.id)

                if faultPoint == .afterFirstDocument, index == 0,
                    edit.documentChanges.count > 1 || !edit.fileOperations.isEmpty
                {
                    throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterFirstDocument.rawValue)
                }
            }

            if faultPoint == .afterDocuments, !edit.fileOperations.isEmpty {
                throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterDocuments.rawValue)
            }
            if faultPoint == .beforeCommit, !edit.fileOperations.isEmpty {
                throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.beforeCommit.rawValue)
            }

            for (index, op) in edit.fileOperations.enumerated() {
                try await applyFileOperation(op, completed: &completedOps, created: &createdURIs)
                if faultPoint == .afterFirstFileOp, index == 0, edit.fileOperations.count > 1 {
                    throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterFirstFileOp.rawValue)
                }
                if faultPoint == .duringRollback, index == 0 {
                    throw WorkspaceEditError.injectedFault("triggerRollback")
                }
            }

            // Success: register undo only now.
            for (change, result) in zip(edit.documentChanges, applied) {
                if let doc = resolveDocument(change) {
                    doc.undo.register(applied: result)
                }
            }

            try await updateJournalState(prepared, state: .committed)
            await cleanupJournal(prepared)

            let inverseOps: [WorkspaceFileOperation] = createdURIs.map { .delete(uri: $0) }
            let result = WorkspaceEditResult(
                appliedDocumentChanges: applied,
                completedFileOperations: completedOps,
                inverse: WorkspaceEdit(
                    documentChanges: inverseDocs.reversed(),
                    fileOperations: inverseOps.reversed()
                ),
                journalURL: nil
            )
            return WorkspaceTransactionReceipt(
                transactionID: prepared.transactionID,
                state: .committed,
                result: result
            )
        } catch {
            let original = String(describing: error)
            try? await updateJournalState(prepared, state: .rollingBack)
            do {
                if faultPoint == .duringRollback {
                    throw WorkspaceEditError.rollbackFailed("injected duringRollback")
                }
                try await rollback(
                    prepared: prepared,
                    inverseDocs: inverseDocs,
                    createdURIs: createdURIs
                )
                try? await updateJournalState(prepared, state: .rolledBack)
                await cleanupJournal(prepared)
            } catch {
                let rollbackMsg = String(describing: error)
                try? await updateJournalState(prepared, state: .recoveryRequired)
                throw WorkspaceEditError.catastrophic(original: original, rollback: rollbackMsg)
            }
            throw error
        }
    }

    /// Discover unfinished journals and roll back / quarantine (WSP-N06).
    public func recoverPendingTransactions() async throws -> WorkspaceRecoveryReport {
        let root = resolvedJournalRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            return WorkspaceRecoveryReport(results: [])
        }
        var results: [WorkspaceRecoveryItem] = []
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        for dir in contents {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if dir.lastPathComponent == "quarantine" { continue }
            let journalURL = dir.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: journalURL.path) else { continue }

            do {
                let data = try Data(contentsOf: journalURL)
                let journal = try DurableWorkspaceJournal.decodeJournal(from: data)

                guard journal.formatVersion == DurableWorkspaceJournal.currentFormatVersion else {
                    try quarantine(directory: dir, reason: "unsupported format \(journal.formatVersion)")
                    results.append(
                        WorkspaceRecoveryItem(
                            transactionID: journal.transactionID,
                            outcome: .quarantined,
                            detail: "unsupported format"
                        )
                    )
                    continue
                }

                let expected = try DurableWorkspaceJournal.computeChecksum(for: journal)
                if journal.checksum.isEmpty || journal.checksum != expected {
                    try quarantine(directory: dir, reason: "checksum mismatch")
                    results.append(
                        WorkspaceRecoveryItem(
                            transactionID: journal.transactionID,
                            outcome: .quarantined,
                            detail: "checksum mismatch"
                        )
                    )
                    continue
                }

                if let escape = resourcePathEscape(journal: journal) {
                    try quarantine(directory: dir, reason: escape)
                    results.append(
                        WorkspaceRecoveryItem(
                            transactionID: journal.transactionID,
                            outcome: .quarantined,
                            detail: escape
                        )
                    )
                    continue
                }

                switch journal.state {
                case .committed, .rolledBack:
                    try? FileManager.default.removeItem(at: dir)
                    results.append(
                        WorkspaceRecoveryItem(
                            transactionID: journal.transactionID,
                            outcome: .skippedClean,
                            detail: journal.state.rawValue
                        )
                    )
                case .preparing, .prepared, .committing, .rollingBack, .recoveryRequired:
                    try restoreBackups(journalDirectory: dir, journal: journal)
                    try? FileManager.default.removeItem(at: dir)
                    results.append(
                        WorkspaceRecoveryItem(
                            transactionID: journal.transactionID,
                            outcome: .rolledBack,
                            detail: "rolled back from \(journal.state.rawValue)"
                        )
                    )
                }
            } catch {
                try? quarantine(directory: dir, reason: String(describing: error))
                results.append(
                    WorkspaceRecoveryItem(
                        transactionID: dir.lastPathComponent,
                        outcome: .quarantined,
                        detail: String(describing: error)
                    )
                )
            }
        }
        return WorkspaceRecoveryReport(results: results)
    }

    // MARK: - Private

    private func resolvedJournalRoot() -> URL {
        journalRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEditorWorkspaceJournals", isDirectory: true)
    }

    private func captureExisting(uri: DocumentURI) throws -> PreparedCapture? {
        guard let url = uri.fileURL else {
            throw WorkspaceEditError.unsupportedURI(uri.rawValue)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let backupName = "backup-\(UUID().uuidString).bin"
        if isDir.boolValue {
            let archive = try WorkspaceArchive.capture(directory: url)
            return PreparedCapture(
                uri: uri,
                isDirectory: true,
                owner: .captureRestore,
                backupFileName: backupName,
                archive: archive,
                posixPermissions: attrs?[.posixPermissions] as? NSNumber,
                modificationDate: attrs?[.modificationDate] as? Date
            )
        }
        #if canImport(Darwin)
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let archive = WorkspaceArchive(
                    entries: [
                        WorkspaceArchive.Entry(
                            relativePath: "",
                            kind: .symlink,
                            linkDestination: dest
                        )
                    ],
                    claimsByteExactMetadata: false
                )
                return PreparedCapture(
                    uri: uri,
                    isDirectory: false,
                    owner: .captureRestore,
                    backupFileName: backupName,
                    archive: archive
                )
            }
        #endif
        let data = try Data(contentsOf: url)
        return PreparedCapture(
            uri: uri,
            isDirectory: false,
            owner: .captureRestore,
            backupFileName: backupName,
            fileBytes: data,
            posixPermissions: attrs?[.posixPermissions] as? NSNumber,
            modificationDate: attrs?[.modificationDate] as? Date
        )
    }

    private func writeDurableJournal(
        transactionID: String,
        state: WorkspaceTransactionState,
        operations: [WorkspaceFileOperation],
        captures: inout [PreparedCapture],
        owners: [RollbackResourceOwner],
        rootPaths: [String]
    ) throws -> (journalURL: URL, directory: URL) {
        let root = resolvedJournalRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(transactionID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var backupNames: [String] = []
        for i in captures.indices {
            let name = captures[i].backupFileName ?? "backup-\(i).bin"
            captures[i].backupFileName = name
            let url = dir.appendingPathComponent(name)
            if let archive = captures[i].archive {
                try archive.encodePayload().write(to: url, options: .atomic)
            } else if let bytes = captures[i].fileBytes {
                try bytes.write(to: url, options: .atomic)
            } else {
                try Data().write(to: url)
            }
            let meta: [String: Any] = [
                "uri": captures[i].uri.rawValue,
                "isDirectory": captures[i].isDirectory,
                "owner": captures[i].owner.rawValue,
                "posixPermissions": captures[i].posixPermissions?.intValue as Any,
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            try metaData.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
            backupNames.append(name)
        }

        // Patch owners with concrete backup names
        var patchedOwners = owners
        for i in patchedOwners.indices {
            if patchedOwners[i].owner == .captureRestore {
                if let cap = captures.first(where: { $0.uri.rawValue == patchedOwners[i].uri }) {
                    patchedOwners[i].relativeBackup = cap.backupFileName
                }
            }
        }

        var journal = DurableWorkspaceJournal(
            transactionID: transactionID,
            // Truncate to whole milliseconds so encode→decode→recompute is bit-stable.
            createdAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1000) / 1000),
            workspaceID: workspace.id.rawValue.uuidString,
            state: state,
            operations: operations.map { Self.stableOperationDescription($0) },
            backupRelativePaths: backupNames,
            rootPaths: rootPaths,
            resourceOwners: patchedOwners,
            checksum: ""
        )
        journal.checksum = try DurableWorkspaceJournal.computeChecksum(for: journal)
        let journalURL = dir.appendingPathComponent("journal.json")
        try DurableWorkspaceJournal.encodeJournal(journal).write(to: journalURL, options: .atomic)
        return (journalURL, dir)
    }

    private static func stableOperationDescription(_ op: WorkspaceFileOperation) -> String {
        switch op {
        case .createFile(let uri, _):
            return "createFile:\(uri.rawValue)"
        case .createFileBytes(let uri, _):
            return "createFileBytes:\(uri.rawValue)"
        case .createDirectory(let uri):
            return "createDirectory:\(uri.rawValue)"
        case .delete(let uri):
            return "delete:\(uri.rawValue)"
        case .rename(let from, let to):
            return "rename:\(from.rawValue)->\(to.rawValue)"
        }
    }

    private func updateJournalState(
        _ prepared: PreparedWorkspaceTransaction,
        state: WorkspaceTransactionState
    ) async throws {
        guard let journalURL = prepared.journalURL,
            FileManager.default.fileExists(atPath: journalURL.path)
        else { return }
        let data = try Data(contentsOf: journalURL)
        var journal = try DurableWorkspaceJournal.decodeJournal(from: data)
        journal.state = state
        journal.checksum = ""
        journal.checksum = try DurableWorkspaceJournal.computeChecksum(for: journal)
        try DurableWorkspaceJournal.encodeJournal(journal).write(to: journalURL, options: .atomic)
        try? fsyncParent(of: journalURL)
    }

    private func cleanupJournal(_ prepared: PreparedWorkspaceTransaction) async {
        if let dir = prepared.journalDirectory {
            try? FileManager.default.removeItem(at: dir)
        } else if let url = prepared.journalURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func rollback(
        prepared: PreparedWorkspaceTransaction,
        inverseDocs: [DocumentChange],
        createdURIs: [DocumentURI]
    ) async throws {
        var errors: [String] = []

        // Capture-owned resources only — never also apply inverse create for same path.
        for cap in prepared.captures.reversed() where cap.owner == .captureRestore {
            do {
                try restoreCapture(cap)
            } catch {
                errors.append("restore \(cap.uri.rawValue): \(error)")
            }
        }

        let captureURIs = Set(prepared.captures.map(\.uri.rawValue))
        for uri in createdURIs.reversed() where !captureURIs.contains(uri.rawValue) {
            if let url = uri.fileURL, FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    errors.append("delete created \(uri.rawValue): \(error)")
                }
            }
        }

        for change in inverseDocs.reversed() {
            guard let doc = resolveDocument(change) else { continue }
            do {
                _ = try doc.apply(change.transaction, sortHighToLow: false, registerUndo: false)
                if let checkpoint = prepared.undoCheckpoints[doc.id] {
                    doc.undo.truncateClosedGroups(to: checkpoint)
                }
            } catch {
                errors.append("doc \(change.uri.rawValue): \(error)")
            }
        }

        for (docID, checkpoint) in prepared.undoCheckpoints {
            if let doc = workspace.documents.document(id: docID) {
                doc.undo.truncateClosedGroups(to: checkpoint)
            }
        }

        if !errors.isEmpty {
            throw WorkspaceEditError.rollbackFailed(errors.joined(separator: "; "))
        }
    }

    private func restoreCapture(_ cap: PreparedCapture) throws {
        guard let url = cap.uri.fileURL else {
            throw WorkspaceEditError.unsupportedURI(cap.uri.rawValue)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if let archive = cap.archive {
            if cap.isDirectory {
                try WorkspaceArchive.restore(archive, to: url)
            } else if let entry = archive.entries.first, entry.kind == .symlink {
                let dest = entry.linkDestination ?? ""
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: dest)
            } else if let entry = archive.entries.first, entry.kind == .regularFile,
                let data = Data(base64Encoded: entry.dataBase64 ?? "")
            {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } else {
                try WorkspaceArchive.restore(archive, to: url)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (cap.fileBytes ?? Data()).write(to: url, options: .atomic)
        }
        if let perms = cap.posixPermissions {
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
        if let date = cap.modificationDate {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    private func restoreBackups(journalDirectory: URL, journal: DurableWorkspaceJournal) throws {
        for owner in journal.resourceOwners where owner.owner == .captureRestore {
            guard let backup = owner.relativeBackup else { continue }
            let backupURL = journalDirectory.appendingPathComponent(backup)
            let metaURL = journalDirectory.appendingPathComponent("\(backup).json")
            guard FileManager.default.fileExists(atPath: backupURL.path),
                let metaData = try? Data(contentsOf: metaURL),
                let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                let uriString = meta["uri"] as? String
            else { continue }

            let fileURL: URL
            if let parsed = URL(string: uriString), parsed.isFileURL {
                fileURL = parsed
            } else {
                fileURL = DocumentURI(rawValue: uriString).fileURL ?? URL(fileURLWithPath: uriString)
            }

            let allowed = journal.rootPaths.contains { root in
                WorkspacePathSecurity.isContained(url: fileURL, inRoot: URL(fileURLWithPath: root))
            }
            guard allowed else {
                throw WorkspaceTransactionError.pathEscape(uriString)
            }

            let isDir = meta["isDirectory"] as? Bool ?? false
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            let payload = try Data(contentsOf: backupURL)
            if isDir {
                if let archive = try? WorkspaceArchive.decodePayload(payload) {
                    try WorkspaceArchive.restore(archive, to: fileURL)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try payload.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func resourcePathEscape(journal: DurableWorkspaceJournal) -> String? {
        if journal.rootPaths.isEmpty,
            journal.resourceOwners.contains(where: { $0.owner == .captureRestore })
        {
            return "missing rootPaths for resource validation"
        }
        for owner in journal.resourceOwners where owner.owner == .captureRestore {
            let fileURL: URL
            if let parsed = URL(string: owner.uri), parsed.isFileURL {
                fileURL = parsed
            } else if let u = DocumentURI(rawValue: owner.uri).fileURL {
                fileURL = u
            } else {
                continue
            }
            let allowed = journal.rootPaths.contains { root in
                WorkspacePathSecurity.isContained(url: fileURL, inRoot: URL(fileURLWithPath: root))
            }
            if !allowed {
                return "path escapes workspace roots: \(owner.uri)"
            }
        }
        return nil
    }

    private func quarantine(directory: URL, reason: String) throws {
        let root = resolvedJournalRoot()
        let q = root.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: q, withIntermediateDirectories: true)
        let dest = q.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: directory, to: dest)
        try reason.data(using: .utf8)?.write(to: dest.appendingPathComponent("QUARANTINE_REASON.txt"))
    }

    private func fsyncParent(of file: URL) throws {
        #if canImport(Darwin)
            let dir = file.deletingLastPathComponent()
            let fd = open(dir.path, O_RDONLY)
            guard fd >= 0 else { return }
            _ = fsync(fd)
            close(fd)
        #endif
    }

    private func liveFileIdentity(for uri: DocumentURI) async throws -> DocumentFileIdentity? {
        guard let url = uri.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        return DocumentFileIdentity(
            contentHash: DocumentFileIdentity.hash(of: data),
            size: UInt64(data.count),
            modificationTime: mtime
        )
    }

    private func resolveDocument(_ change: DocumentChange) -> TextDocument? {
        if let id = change.documentID, let doc = workspace.lifecycle.document(id: id) {
            return doc
        }
        return workspace.lifecycle.document(uri: change.uri)
            ?? workspace.documents.document(uri: change.uri)
    }

    private func preflightFileOperation(_ op: WorkspaceFileOperation, touched: inout Set<String>) async throws {
        func touch(_ uri: DocumentURI) throws {
            guard let path = uri.fileURL?.standardizedFileURL.path else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            if !touched.insert(path).inserted {
                throw WorkspaceEditError.overlappingOperations(path)
            }
        }
        switch op {
        case .createFile(let uri, _), .createFileBytes(let uri, _), .createDirectory(let uri):
            try touch(uri)
            if let url = uri.fileURL, FileManager.default.fileExists(atPath: url.path) {
                throw WorkspaceEditError.validationFailed("already exists: \(uri.rawValue)")
            }
        case .delete(let uri):
            try touch(uri)
            guard await workspace.fileSystem.item(for: uri) != nil else {
                throw WorkspaceEditError.documentNotFound(uri.rawValue)
            }
        case .rename(let from, let to):
            try touch(from)
            try touch(to)
            guard await workspace.fileSystem.item(for: from) != nil else {
                throw WorkspaceEditError.documentNotFound(from.rawValue)
            }
            if let url = to.fileURL, FileManager.default.fileExists(atPath: url.path) {
                throw WorkspaceEditError.validationFailed("rename target exists: \(to.rawValue)")
            }
        }
    }

    private func applyFileOperation(
        _ op: WorkspaceFileOperation,
        completed: inout [WorkspaceFileOperation],
        created: inout [DocumentURI]
    ) async throws {
        switch op {
        case .createFile(let uri, let contents):
            guard let parentItem = await parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let item = try await workspace.fileSystem.createFile(
                in: parentItem, name: name, contents: Data(contents.utf8)
            )
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            created.append(uri)

        case .createFileBytes(let uri, let b64):
            guard let parentItem = await parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            guard let data = Data(base64Encoded: b64) else {
                throw WorkspaceEditError.validationFailed("invalid base64 for \(uri.rawValue)")
            }
            let item = try await workspace.fileSystem.createFile(in: parentItem, name: name, contents: data)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            created.append(uri)

        case .createDirectory(let uri):
            guard let parentItem = await parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let item = try await workspace.fileSystem.createDirectory(in: parentItem, name: name)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            created.append(uri)

        case .delete(let uri):
            guard let item = await workspace.fileSystem.item(for: uri) else {
                throw WorkspaceEditError.documentNotFound(uri.rawValue)
            }
            try await workspace.fileSystem.delete(item: item.id)
            workspace.fileTree.apply(.removed(item.id))
            if let doc = workspace.lifecycle.document(uri: uri) {
                _ = try await workspace.lifecycle.close(
                    documentID: doc.id,
                    reason: .deletedFromWorkspace
                )
            }
            completed.append(op)

        case .rename(let from, let to):
            guard let item = await workspace.fileSystem.item(for: from) else {
                throw WorkspaceEditError.documentNotFound(from.rawValue)
            }
            guard let parentItem = await parentItem(for: to), let name = fileName(for: to) else {
                throw WorkspaceEditError.unsupportedURI(to.rawValue)
            }
            let moved = try await workspace.fileSystem.move(item: item.id, to: parentItem, newName: name)
            workspace.fileTree.apply(.renamed(from: item.id, to: moved))
            if let doc = workspace.lifecycle.document(uri: from) {
                try await workspace.lifecycle.rename(documentID: doc.id, to: to)
                workspace.updateTabURIs(documentID: doc.id, uri: to)
            }
            completed.append(op)
        }
    }

    private func parentItem(for uri: DocumentURI) async -> WorkspaceItemID? {
        guard let url = uri.fileURL else { return nil }
        let parentURL = url.deletingLastPathComponent()
        let parentURI = DocumentURI(fileURL: parentURL)
        if let item = await workspace.fileSystem.item(for: parentURI) {
            return item.id
        }
        for root in await workspace.fileSystem.roots {
            if root.uri.fileURL?.standardizedFileURL == parentURL.standardizedFileURL {
                return WorkspaceItemID(rootID: root.id, path: "")
            }
        }
        return nil
    }

    private func fileName(for uri: DocumentURI) -> String? {
        uri.fileURL?.lastPathComponent
    }
}
