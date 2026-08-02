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
    /// Both original failure and rollback failure preserved (WSP-N01).
    case catastrophic(original: String, rollback: String)
    case injectedFault(String)
}

/// Ordered steps for fault injection during transactional apply.
public enum WorkspaceEditFaultPoint: String, Sendable, Hashable {
    case afterFirstDocument
    case afterDocuments
    case afterFirstFileOp
    case beforeCommit
    /// After first FS op succeeds, throw to enter rollback; restore then fails (E4).
    case duringRollback
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
        let root = journalRoot ?? workspace.journalRoot
        let coordinator = WorkspaceTransactionCoordinator(workspace: workspace, journalRoot: root)
        _ = try await coordinator.prepare(WorkspaceTransactionRequest(edit: edit))
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

    /// Transactional apply via ``WorkspaceTransactionCoordinator`` (WSP-N01 / WSP-N06).
    /// Prepare → commit; undo registered only on success; one rollback owner per resource.
    public func apply(_ edit: WorkspaceEdit) async throws -> WorkspaceEditResult {
        let root = journalRoot ?? workspace.journalRoot
        let coordinator = WorkspaceTransactionCoordinator(workspace: workspace, journalRoot: root)
        coordinator.faultPoint = faultPoint
        let prepared = try await coordinator.prepare(WorkspaceTransactionRequest(edit: edit))
        let receipt = try await coordinator.commit(prepared)
        guard let result = receipt.result else {
            throw WorkspaceEditError.validationFailed("commit produced no result")
        }
        return result
    }

    private func resolveDocument(_ change: DocumentChange) -> TextDocument? {
        if let id = change.documentID, let doc = workspace.lifecycle.document(id: id) {
            return doc
        }
        return workspace.lifecycle.document(uri: change.uri)
            ?? workspace.documents.document(uri: change.uri)
    }
}
