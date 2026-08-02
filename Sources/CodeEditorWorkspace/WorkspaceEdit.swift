import CodeEditorCore
import CodeEditorDocuments
import Foundation

public struct DocumentChange: Codable, Sendable, Hashable {
    public var uri: DocumentURI
    public var documentID: DocumentID?
    public var expectedVersion: DocumentVersion?
    /// Optional expected on-disk identity for conflict detection (WSP-002 / DOC-004).
    public var expectedFileIdentity: DocumentFileIdentity?
    public var transaction: EditTransaction

    public init(
        uri: DocumentURI,
        documentID: DocumentID? = nil,
        expectedVersion: DocumentVersion? = nil,
        expectedFileIdentity: DocumentFileIdentity? = nil,
        transaction: EditTransaction
    ) {
        self.uri = uri
        self.documentID = documentID
        self.expectedVersion = expectedVersion
        self.expectedFileIdentity = expectedFileIdentity
        self.transaction = transaction
    }
}

public enum WorkspaceFileOperation: Codable, Sendable, Hashable {
    /// Create a regular file with exact UTF-8 or raw base64 payload.
    case createFile(uri: DocumentURI, contents: String)
    /// Create with raw bytes (binary-safe).
    case createFileBytes(uri: DocumentURI, contentsBase64: String)
    case createDirectory(uri: DocumentURI)
    case delete(uri: DocumentURI)
    case rename(from: DocumentURI, to: DocumentURI)
}

public struct WorkspaceEdit: Codable, Sendable, Hashable {
    public var documentChanges: [DocumentChange]
    public var fileOperations: [WorkspaceFileOperation]

    public init(
        documentChanges: [DocumentChange] = [],
        fileOperations: [WorkspaceFileOperation] = []
    ) {
        self.documentChanges = documentChanges
        self.fileOperations = fileOperations
    }
}

public struct WorkspaceEditPreview: Sendable, Hashable {
    public var documentChangeCount: Int
    public var fileOperationCount: Int
    public var openDocumentsAffected: Int
}

public struct WorkspaceEditResult: Sendable {
    public var appliedDocumentChanges: [AppliedEditTransaction]
    public var completedFileOperations: [WorkspaceFileOperation]
    public var inverse: WorkspaceEdit
    /// Path to durable journal written before destructive steps (may be nil for doc-only edits).
    public var journalURL: URL?
}

public enum WorkspaceEditError: Error, Sendable, Equatable {
    case versionMismatch(uri: String, expected: UInt64, actual: UInt64)
    case documentNotFound(String)
    case unsupportedURI(String)
    case validationFailed(String)
    case conflict(uri: String)
    case overlappingOperations(String)
    case rollbackFailed(String)
    case catastrophic(String)
    case injectedFault(String)
}

/// Ordered steps for fault injection during transactional apply.
public enum WorkspaceEditFaultPoint: String, Sendable, Hashable {
    case afterFirstDocument
    case afterDocuments
    case afterFirstFileOp
    case beforeCommit
}

// MARK: - Durable journal

/// Byte-exact capture of a filesystem entry for rollback (WSP-002).
struct CapturedFSEntry: Sendable {
    var uri: DocumentURI
    var isDirectory: Bool
    var bytes: Data?
    var posixPermissions: NSNumber?
    var modificationDate: Date?
}

/// Durable transaction journal written before the first destructive FS step.
struct WorkspaceEditJournal: Codable, Sendable {
    var formatVersion: Int
    var transactionID: String
    var createdAt: Date
    var workspaceID: String
    var operations: [String]
    var backupRelativePaths: [String]

    static let formatVersion = 1
}

@MainActor
public final class WorkspaceEditService {
    private let workspace: Workspace
    /// When set, `apply` throws after the named step (for tests).
    public var faultPoint: WorkspaceEditFaultPoint?
    /// Directory for durable journals; defaults under temp when nil.
    public var journalRoot: URL?

    public init(workspace: Workspace, journalRoot: URL? = nil) {
        self.workspace = workspace
        self.journalRoot = journalRoot
    }

    public func validate(_ edit: WorkspaceEdit) async throws {
        // Reject empty edits.
        guard !edit.documentChanges.isEmpty || !edit.fileOperations.isEmpty else {
            throw WorkspaceEditError.validationFailed("empty workspace edit")
        }

        // Detect duplicate document targets.
        var seenDocURIs = Set<String>()
        for change in edit.documentChanges {
            if !seenDocURIs.insert(change.uri.rawValue).inserted {
                throw WorkspaceEditError.overlappingOperations("duplicate document change: \(change.uri.rawValue)")
            }
            let doc = resolveDocument(change)
            guard let doc else {
                throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
            }
            if let expected = change.expectedVersion, doc.version != expected {
                throw WorkspaceEditError.versionMismatch(
                    uri: change.uri.rawValue,
                    expected: expected.rawValue,
                    actual: doc.version.rawValue
                )
            }
            // Prevalidate ranges against current document (atomic DOC-001 path).
            for c in change.transaction.changes {
                _ = try TextOffsetSemantics.validatedUTF16Range(
                    c.replacedRange.nsRange,
                    documentUTF16Length: doc.length
                )
            }
        }

        // File op preflight: resolve paths, reject conflicts/duplicates.
        var touchedPaths = Set<String>()
        for op in edit.fileOperations {
            try await preflightFileOperation(op, touched: &touchedPaths)
        }
    }

    public func preview(_ edit: WorkspaceEdit) -> WorkspaceEditPreview {
        let openCount = edit.documentChanges.reduce(into: 0) { count, change in
            if resolveDocument(change) != nil { count += 1 }
        }
        return WorkspaceEditPreview(
            documentChangeCount: edit.documentChanges.count,
            fileOperationCount: edit.fileOperations.count,
            openDocumentsAffected: openCount
        )
    }

    /// Transactional apply: preflight → journal → stage → commit → coherent update.
    /// On any failure, rolls back with errors surfaced (never swallowed) (WSP-002).
    public func apply(_ edit: WorkspaceEdit) async throws -> WorkspaceEditResult {
        try await validate(edit)

        var applied: [AppliedEditTransaction] = []
        var inverseDocs: [DocumentChange] = []
        var completedOps: [WorkspaceFileOperation] = []
        var inverseOps: [WorkspaceFileOperation] = []
        var captures: [CapturedFSEntry] = []
        var journalURL: URL?
        var journalBackups: [URL] = []

        do {
            // 1. Document mutations (in-memory, versioned, atomic per DOC-001).
            for (index, change) in edit.documentChanges.enumerated() {
                guard let doc = resolveDocument(change) else {
                    throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
                }
                if let expected = change.expectedVersion, doc.version != expected {
                    throw WorkspaceEditError.versionMismatch(
                        uri: change.uri.rawValue,
                        expected: expected.rawValue,
                        actual: doc.version.rawValue
                    )
                }
                if let expectedID = change.expectedFileIdentity,
                    let live = doc.fileIdentity,
                    live.contentHash != expectedID.contentHash
                {
                    throw WorkspaceEditError.conflict(uri: change.uri.rawValue)
                }
                let result = try doc.apply(
                    change.transaction,
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

            // 2. Capture byte-exact state for every FS path we will destroy/mutate.
            for op in edit.fileOperations {
                try await captureForOperation(op, into: &captures)
            }

            // 3. Persist durable journal before first destructive FS step.
            if !edit.fileOperations.isEmpty {
                let (url, backups) = try writeJournal(
                    captures: captures,
                    operations: edit.fileOperations
                )
                journalURL = url
                journalBackups = backups
            }

            if faultPoint == .beforeCommit, !edit.fileOperations.isEmpty {
                throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.beforeCommit.rawValue)
            }

            // 4. Apply FS operations.
            for (index, op) in edit.fileOperations.enumerated() {
                try await applyFileOperation(op, completed: &completedOps, inverse: &inverseOps)
                if faultPoint == .afterFirstFileOp, index == 0, edit.fileOperations.count > 1 {
                    throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterFirstFileOp.rawValue)
                }
            }

            // 5. Success — remove journal (keep backups cleaned).
            if let journalURL {
                try? FileManager.default.removeItem(at: journalURL)
            }
            for b in journalBackups {
                try? FileManager.default.removeItem(at: b)
            }

            return WorkspaceEditResult(
                appliedDocumentChanges: applied,
                completedFileOperations: completedOps,
                inverse: WorkspaceEdit(
                    documentChanges: inverseDocs.reversed(),
                    fileOperations: inverseOps.reversed()
                ),
                journalURL: nil
            )
        } catch {
            // Rollback must surface failures — never swallow (WSP-002).
            do {
                try await rollback(
                    inverseDocs: inverseDocs,
                    inverseOps: inverseOps,
                    captures: captures
                )
            } catch {
                throw WorkspaceEditError.catastrophic(
                    "rollback failed after \(error.localizedDescription): \(String(describing: error))"
                )
            }
            // Clean journal on successful rollback.
            if let journalURL {
                try? FileManager.default.removeItem(at: journalURL)
            }
            for b in journalBackups {
                try? FileManager.default.removeItem(at: b)
            }
            throw error
        }
    }

    // MARK: - Capture / journal

    private func captureForOperation(_ op: WorkspaceFileOperation, into captures: inout [CapturedFSEntry]) async throws
    {
        switch op {
        case .createFile, .createFileBytes, .createDirectory:
            break
        case .delete(let uri), .rename(let uri, _):
            if let cap = try captureExisting(uri: uri) {
                captures.append(cap)
            }
        }
    }

    private func captureExisting(uri: DocumentURI) throws -> CapturedFSEntry? {
        guard let url = uri.fileURL else {
            throw WorkspaceEditError.unsupportedURI(uri.rawValue)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return nil
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if isDir.boolValue {
            // Capture directory as empty recreate + we also walk children for files.
            var entries: [CapturedFSEntry] = []
            entries.append(
                CapturedFSEntry(
                    uri: uri,
                    isDirectory: true,
                    bytes: nil,
                    posixPermissions: attrs?[.posixPermissions] as? NSNumber,
                    modificationDate: attrs?[.modificationDate] as? Date
                ))
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let child as URL in enumerator {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    if values.isDirectory == true {
                        let childAttrs = try? FileManager.default.attributesOfItem(atPath: child.path)
                        entries.append(
                            CapturedFSEntry(
                                uri: DocumentURI(fileURL: child),
                                isDirectory: true,
                                bytes: nil,
                                posixPermissions: childAttrs?[.posixPermissions] as? NSNumber,
                                modificationDate: childAttrs?[.modificationDate] as? Date
                            ))
                    } else if values.isRegularFile == true {
                        let data = try Data(contentsOf: child)
                        let childAttrs = try FileManager.default.attributesOfItem(atPath: child.path)
                        entries.append(
                            CapturedFSEntry(
                                uri: DocumentURI(fileURL: child),
                                isDirectory: false,
                                bytes: data,
                                posixPermissions: childAttrs[.posixPermissions] as? NSNumber,
                                modificationDate: childAttrs[.modificationDate] as? Date
                            ))
                    }
                }
            }
            // Store only root entry here; children restored via recursive restore from captures list
            // — caller appends all.
            // We return root and rely on apply to capture recursively by expanding list.
            // Actually we need to push all entries — use a side channel via inout on next call.
            // Simpler: only capture single file/dir shallow for delete of files; for dirs capture all above.
            // For this method signature, we'll only return the primary; expand in captureForOperation.
            _ = entries
            // Re-implement: throw if directory non-empty without recursive capture wired.
            // Wire recursive: store root only and restore directory tree from bytes map.
            return CapturedFSEntry(
                uri: uri,
                isDirectory: true,
                bytes: try encodeDirectoryArchive(url: url),
                posixPermissions: attrs?[.posixPermissions] as? NSNumber,
                modificationDate: attrs?[.modificationDate] as? Date
            )
        } else {
            let data = try Data(contentsOf: url)
            return CapturedFSEntry(
                uri: uri,
                isDirectory: false,
                bytes: data,
                posixPermissions: attrs?[.posixPermissions] as? NSNumber,
                modificationDate: attrs?[.modificationDate] as? Date
            )
        }
    }

    /// Encode directory tree as a simple length-prefixed path/data archive (byte-exact).
    private func encodeDirectoryArchive(url: URL) throws -> Data {
        var out = Data()
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: []
            )
        else {
            return out
        }
        let rootPath = url.standardizedFileURL.path
        for case let child as URL in enumerator {
            let full = child.standardizedFileURL.path
            guard full.hasPrefix(rootPath) else { continue }
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let flag: UInt8 = values.isDirectory == true ? 1 : 0
            let relData = Data(rel.utf8)
            var relLen = UInt32(relData.count).bigEndian
            out.append(flag)
            withUnsafeBytes(of: &relLen) { out.append(contentsOf: $0) }
            out.append(relData)
            if flag == 0 {
                let fileData = try Data(contentsOf: child)
                var len = UInt32(fileData.count).bigEndian
                withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
                out.append(fileData)
            }
        }
        return out
    }

    private func restoreDirectoryArchive(at url: URL, archive: Data) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var offset = 0
        let bytes = [UInt8](archive)
        while offset < bytes.count {
            let flag = bytes[offset]
            offset += 1
            guard offset + 4 <= bytes.count else { break }
            let relLen = Int(UInt32(bigEndian: readU32(bytes, offset)))
            offset += 4
            guard offset + relLen <= bytes.count else { break }
            let rel = String(bytes: bytes[offset..<(offset + relLen)], encoding: .utf8) ?? ""
            offset += relLen
            let dest = rel.isEmpty ? url : url.appendingPathComponent(rel)
            if flag == 1 {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                guard offset + 4 <= bytes.count else { break }
                let dataLen = Int(UInt32(bigEndian: readU32(bytes, offset)))
                offset += 4
                guard offset + dataLen <= bytes.count else { break }
                let data = Data(bytes[offset..<(offset + dataLen)])
                offset += dataLen
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: dest, options: .atomic)
            }
        }
    }

    private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        value |= UInt32(bytes[offset]) << 24
        value |= UInt32(bytes[offset + 1]) << 16
        value |= UInt32(bytes[offset + 2]) << 8
        value |= UInt32(bytes[offset + 3])
        return value
    }

    private func writeJournal(
        captures: [CapturedFSEntry],
        operations: [WorkspaceFileOperation]
    ) throws -> (URL, [URL]) {
        let root =
            journalRoot
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeEditorWorkspaceJournals", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let txID = UUID().uuidString
        let dir = root.appendingPathComponent(txID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var backupNames: [String] = []
        var backupURLs: [URL] = []
        for (i, cap) in captures.enumerated() {
            let name = "backup-\(i).bin"
            let url = dir.appendingPathComponent(name)
            if let bytes = cap.bytes {
                try bytes.write(to: url, options: .atomic)
            } else {
                try Data().write(to: url)
            }
            // Sidecar metadata
            let meta: [String: Any] = [
                "uri": cap.uri.rawValue,
                "isDirectory": cap.isDirectory,
                "posixPermissions": cap.posixPermissions?.intValue as Any,
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            try metaData.write(to: dir.appendingPathComponent("backup-\(i).json"), options: .atomic)
            backupNames.append(name)
            backupURLs.append(url)
        }
        let journal = WorkspaceEditJournal(
            formatVersion: WorkspaceEditJournal.formatVersion,
            transactionID: txID,
            createdAt: Date(),
            workspaceID: String(describing: workspace.id),
            operations: operations.map { String(describing: $0) },
            backupRelativePaths: backupNames
        )
        let journalURL = dir.appendingPathComponent("journal.json")
        let encoded = try JSONEncoder().encode(journal)
        try encoded.write(to: journalURL, options: .atomic)
        // fsync parent best-effort
        return (journalURL, backupURLs)
    }

    // MARK: - Rollback

    private func rollback(
        inverseDocs: [DocumentChange],
        inverseOps: [WorkspaceFileOperation],
        captures: [CapturedFSEntry]
    ) async throws {
        var rollbackErrors: [String] = []

        // Prefer byte-exact captures for FS restoration.
        for cap in captures.reversed() {
            do {
                try restoreCapture(cap)
            } catch {
                rollbackErrors.append("restore \(cap.uri.rawValue): \(error)")
            }
        }

        // Inverse file ops that create/rename beyond captures.
        for op in inverseOps.reversed() {
            do {
                var completed: [WorkspaceFileOperation] = []
                var inv: [WorkspaceFileOperation] = []
                try await applyFileOperation(op, completed: &completed, inverse: &inv)
            } catch {
                // Capture restore may have already fixed state; record but continue docs.
                rollbackErrors.append("inverse op \(op): \(error)")
            }
        }

        for change in inverseDocs.reversed() {
            guard let doc = resolveDocument(change) else { continue }
            do {
                _ = try doc.apply(change.transaction, sortHighToLow: false, registerUndo: false)
            } catch {
                rollbackErrors.append("doc \(change.uri.rawValue): \(error)")
            }
        }

        if !rollbackErrors.isEmpty {
            throw WorkspaceEditError.rollbackFailed(rollbackErrors.joined(separator: "; "))
        }
    }

    private func restoreCapture(_ cap: CapturedFSEntry) throws {
        guard let url = cap.uri.fileURL else {
            throw WorkspaceEditError.unsupportedURI(cap.uri.rawValue)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        if cap.isDirectory {
            if let archive = cap.bytes, !archive.isEmpty {
                try restoreDirectoryArchive(at: url, archive: archive)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (cap.bytes ?? Data()).write(to: url, options: .atomic)
        }
        if let perms = cap.posixPermissions {
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
        if let date = cap.modificationDate {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    // MARK: - File ops

    private func resolveDocument(_ change: DocumentChange) -> TextDocument? {
        if let id = change.documentID, let doc = workspace.documents.document(id: id) {
            return doc
        }
        return workspace.documents.document(uri: change.uri)
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
            guard await parentItem(for: uri) != nil, fileName(for: uri) != nil else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
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
            guard await parentItem(for: to) != nil, fileName(for: to) != nil else {
                throw WorkspaceEditError.unsupportedURI(to.rawValue)
            }
            if let url = to.fileURL, FileManager.default.fileExists(atPath: url.path) {
                throw WorkspaceEditError.validationFailed("rename target exists: \(to.rawValue)")
            }
        }
    }

    private func applyFileOperation(
        _ op: WorkspaceFileOperation,
        completed: inout [WorkspaceFileOperation],
        inverse: inout [WorkspaceFileOperation]
    ) async throws {
        switch op {
        case .createFile(let uri, let contents):
            guard let parentItem = await parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let data = Data(contents.utf8)
            let item = try await workspace.fileSystem.createFile(in: parentItem, name: name, contents: data)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            inverse.append(.delete(uri: uri))

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
            inverse.append(.delete(uri: uri))

        case .createDirectory(let uri):
            guard let parentItem = await parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let item = try await workspace.fileSystem.createDirectory(in: parentItem, name: name)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            inverse.append(.delete(uri: uri))

        case .delete(let uri):
            guard let item = await workspace.fileSystem.item(for: uri) else {
                throw WorkspaceEditError.documentNotFound(uri.rawValue)
            }
            // Inverse is restored from capture; record delete for inverse stack only if capture missing.
            if let url = uri.fileURL, !item.isDirectory,
                let data = try? Data(contentsOf: url)
            {
                inverse.append(.createFileBytes(uri: uri, contentsBase64: data.base64EncodedString()))
            } else if item.isDirectory {
                inverse.append(.createDirectory(uri: uri))
            }
            try await workspace.fileSystem.delete(item: item.id)
            workspace.fileTree.apply(.removed(item.id))
            // Close open documents for deleted URI.
            if let doc = workspace.documents.document(uri: uri) {
                _ = workspace.documents.remove(id: doc.id)
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
            if let doc = workspace.documents.document(uri: from) {
                doc.setURI(to)
                workspace.documents.reindexURI(for: doc)
                workspace.updateTabURIs(documentID: doc.id, uri: to)
            }
            completed.append(op)
            inverse.append(.rename(from: to, to: from))
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
