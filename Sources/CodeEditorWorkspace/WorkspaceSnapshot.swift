import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Immutable Sendable view of workspace state for concurrency / search / extensions.
public struct WorkspaceSnapshot: Sendable, Hashable {
    public var workspaceID: WorkspaceID
    public var revision: UInt64
    public var roots: [WorkspaceRoot]
    public var openDocumentIDs: [DocumentID]
    public var documentVersions: [DocumentURI: DocumentVersion]
    public var activePaneID: EditorPaneID?
    public var trust: WorkspaceTrustState

    public init(
        workspaceID: WorkspaceID,
        revision: UInt64,
        roots: [WorkspaceRoot],
        openDocumentIDs: [DocumentID],
        documentVersions: [DocumentURI: DocumentVersion],
        activePaneID: EditorPaneID?,
        trust: WorkspaceTrustState
    ) {
        self.workspaceID = workspaceID
        self.revision = revision
        self.roots = roots
        self.openDocumentIDs = openDocumentIDs
        self.documentVersions = documentVersions
        self.activePaneID = activePaneID
        self.trust = trust
    }
}

/// Host policy for dirty tabs when closing panes/workspace.
public enum DirtyTabClosePolicy: String, Sendable, Hashable, Codable, CaseIterable {
    case prompt
    case save
    case discard
    case cancel
}
