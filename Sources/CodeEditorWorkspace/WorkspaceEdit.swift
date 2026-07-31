import Foundation
import CodeEditorCore
import CodeEditorDocuments

public struct DocumentChange: Codable, Sendable, Hashable {
    public var uri: DocumentURI
    public var documentID: DocumentID?
    public var expectedVersion: DocumentVersion?
    public var transaction: EditTransaction

    public init(
        uri: DocumentURI,
        documentID: DocumentID? = nil,
        expectedVersion: DocumentVersion? = nil,
        transaction: EditTransaction
    ) {
        self.uri = uri
        self.documentID = documentID
        self.expectedVersion = expectedVersion
        self.transaction = transaction
    }
}

public enum WorkspaceFileOperation: Codable, Sendable, Hashable {
    case createFile(uri: DocumentURI, contents: String)
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
}

public enum WorkspaceEditError: Error, Sendable, Equatable {
    case versionMismatch(uri: String, expected: UInt64, actual: UInt64)
    case documentNotFound(String)
    case unsupportedURI(String)
    case validationFailed(String)
    case rollbackFailed(String)
    case injectedFault(String)
}

/// Ordered steps for fault injection during transactional apply.
public enum WorkspaceEditFaultPoint: String, Sendable, Hashable {
    case afterFirstDocument
    case afterDocuments
    case afterFirstFileOp
}

@MainActor
public final class WorkspaceEditService {
    private let workspace: Workspace
    /// When set, `apply` throws after the named step (for tests).
    public var faultPoint: WorkspaceEditFaultPoint?

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public func validate(_ edit: WorkspaceEdit) throws {
        for change in edit.documentChanges {
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
        }
        for op in edit.fileOperations {
            try preflightFileOperation(op)
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

    /// Transactional apply: preflight → mutate with journal → rollback on failure.
    public func apply(_ edit: WorkspaceEdit) async throws -> WorkspaceEditResult {
        try validate(edit)

        var applied: [AppliedEditTransaction] = []
        var inverseDocs: [DocumentChange] = []
        var completedOps: [WorkspaceFileOperation] = []
        var inverseOps: [WorkspaceFileOperation] = []

        do {
            for (index, change) in edit.documentChanges.enumerated() {
                guard let doc = resolveDocument(change) else {
                    throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
                }
                // Re-check version immediately before mutation (stale-revision gate).
                if let expected = change.expectedVersion, doc.version != expected {
                    throw WorkspaceEditError.versionMismatch(
                        uri: change.uri.rawValue,
                        expected: expected.rawValue,
                        actual: doc.version.rawValue
                    )
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

                if faultPoint == .afterFirstDocument, index == 0, edit.documentChanges.count > 1
                    || (faultPoint == .afterFirstDocument && !edit.fileOperations.isEmpty) {
                    throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterFirstDocument.rawValue)
                }
            }

            if faultPoint == .afterDocuments, !edit.fileOperations.isEmpty {
                throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterDocuments.rawValue)
            }

            for (index, op) in edit.fileOperations.enumerated() {
                try await applyFileOperation(op, completed: &completedOps, inverse: &inverseOps)
                if faultPoint == .afterFirstFileOp, index == 0, edit.fileOperations.count > 1 {
                    throw WorkspaceEditError.injectedFault(WorkspaceEditFaultPoint.afterFirstFileOp.rawValue)
                }
            }
        } catch {
            try? await rollback(
                inverseDocs: inverseDocs,
                inverseOps: inverseOps
            )
            throw error
        }

        return WorkspaceEditResult(
            appliedDocumentChanges: applied,
            completedFileOperations: completedOps,
            inverse: WorkspaceEdit(
                documentChanges: inverseDocs.reversed(),
                fileOperations: inverseOps.reversed()
            )
        )
    }

    private func rollback(
        inverseDocs: [DocumentChange],
        inverseOps: [WorkspaceFileOperation]
    ) async throws {
        // Reverse file ops first (they depend on post-edit paths), then docs.
        for op in inverseOps.reversed() {
            var completed: [WorkspaceFileOperation] = []
            var inv: [WorkspaceFileOperation] = []
            try await applyFileOperation(op, completed: &completed, inverse: &inv)
        }
        for change in inverseDocs.reversed() {
            guard let doc = resolveDocument(change) else { continue }
            _ = try doc.apply(change.transaction, sortHighToLow: false, registerUndo: false)
        }
    }

    private func resolveDocument(_ change: DocumentChange) -> TextDocument? {
        if let id = change.documentID, let doc = workspace.documents.document(id: id) {
            return doc
        }
        return workspace.documents.document(uri: change.uri)
    }

    private func preflightFileOperation(_ op: WorkspaceFileOperation) throws {
        switch op {
        case .createFile(let uri, _), .createDirectory(let uri):
            guard parentItem(for: uri) != nil, fileName(for: uri) != nil else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
        case .delete(let uri):
            guard workspace.fileSystem.item(for: uri) != nil else {
                throw WorkspaceEditError.documentNotFound(uri.rawValue)
            }
        case .rename(let from, let to):
            guard workspace.fileSystem.item(for: from) != nil else {
                throw WorkspaceEditError.documentNotFound(from.rawValue)
            }
            guard parentItem(for: to) != nil, fileName(for: to) != nil else {
                throw WorkspaceEditError.unsupportedURI(to.rawValue)
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
            guard let parentItem = parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let data = Data(contents.utf8)
            let item = try await workspace.fileSystem.createFile(in: parentItem, name: name, contents: data)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            inverse.append(.delete(uri: uri))

        case .createDirectory(let uri):
            guard let parentItem = parentItem(for: uri), let name = fileName(for: uri) else {
                throw WorkspaceEditError.unsupportedURI(uri.rawValue)
            }
            let item = try await workspace.fileSystem.createDirectory(in: parentItem, name: name)
            workspace.fileTree.apply(.added(item))
            completed.append(op)
            inverse.append(.delete(uri: uri))

        case .delete(let uri):
            guard let item = workspace.fileSystem.item(for: uri) else {
                throw WorkspaceEditError.documentNotFound(uri.rawValue)
            }
            // Capture content for rollback of plain files when possible.
            var restoreContents: String?
            if let fileURL = uri.fileURL,
               let data = try? Data(contentsOf: fileURL),
               let text = String(data: data, encoding: .utf8) {
                restoreContents = text
            }
            try await workspace.fileSystem.delete(item: item.id)
            workspace.fileTree.apply(.removed(item.id))
            completed.append(op)
            if let restoreContents, !item.isDirectory {
                inverse.append(.createFile(uri: uri, contents: restoreContents))
            } else if item.isDirectory {
                inverse.append(.createDirectory(uri: uri))
            }

        case .rename(let from, let to):
            guard let item = workspace.fileSystem.item(for: from) else {
                throw WorkspaceEditError.documentNotFound(from.rawValue)
            }
            guard let parentItem = parentItem(for: to), let name = fileName(for: to) else {
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

    private func parentItem(for uri: DocumentURI) -> WorkspaceItemID? {
        guard let url = uri.fileURL else { return nil }
        let parentURL = url.deletingLastPathComponent()
        let parentURI = DocumentURI(fileURL: parentURL)
        if let item = workspace.fileSystem.item(for: parentURI) {
            return item.id
        }
        for root in workspace.fileSystem.roots {
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
