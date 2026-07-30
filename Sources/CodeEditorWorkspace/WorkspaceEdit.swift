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
}

@MainActor
public final class WorkspaceEditService {
    private let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public func validate(_ edit: WorkspaceEdit) throws {
        for change in edit.documentChanges {
            if let expected = change.expectedVersion {
                let doc = resolveDocument(change)
                guard let doc else {
                    throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
                }
                if doc.version != expected {
                    throw WorkspaceEditError.versionMismatch(
                        uri: change.uri.rawValue,
                        expected: expected.rawValue,
                        actual: doc.version.rawValue
                    )
                }
            }
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

    public func apply(_ edit: WorkspaceEdit) async throws -> WorkspaceEditResult {
        try validate(edit)
        var applied: [AppliedEditTransaction] = []
        var inverseDocs: [DocumentChange] = []

        for change in edit.documentChanges {
            guard let doc = resolveDocument(change) else {
                throw WorkspaceEditError.documentNotFound(change.uri.rawValue)
            }
            let result = try doc.apply(change.transaction)
            applied.append(result)
            inverseDocs.append(
                DocumentChange(
                    uri: change.uri,
                    documentID: doc.id,
                    expectedVersion: result.newVersion,
                    transaction: result.inverse
                )
            )
            // Promote preview tabs when document is edited.
            workspace.promotePreviewTabs(for: doc.id)
        }

        var completedOps: [WorkspaceFileOperation] = []
        var inverseOps: [WorkspaceFileOperation] = []
        for op in edit.fileOperations {
            try await applyFileOperation(op, completed: &completedOps, inverse: &inverseOps)
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

    private func resolveDocument(_ change: DocumentChange) -> TextDocument? {
        if let id = change.documentID, let doc = workspace.documents.document(id: id) {
            return doc
        }
        return workspace.documents.document(uri: change.uri)
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
            try await workspace.fileSystem.delete(item: item.id)
            workspace.fileTree.apply(.removed(item.id))
            completed.append(op)
            // Best-effort inverse: recreate empty file/dir not always possible; skip full content restore.

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
        // Parent may be a root directory.
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
