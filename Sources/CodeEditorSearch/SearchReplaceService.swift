import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Applies a search-replace plan through transactional ``WorkspaceEditService``.
@MainActor
public enum SearchReplaceService {
    public static func apply(
        plan: SearchReplacePlan,
        to workspace: Workspace,
        preserveCase: Bool = false
    ) async throws -> WorkspaceEditResult {
        var versions: [DocumentURI: DocumentVersion] = [:]
        var texts: [DocumentURI: String] = [:]
        for doc in workspace.documents.documents {
            versions[doc.uri] = doc.version
            texts[doc.uri] = doc.text
        }
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: plan,
            openDocumentVersions: versions,
            documentTexts: texts,
            preserveCase: preserveCase
        )
        let service = WorkspaceEditService(workspace: workspace)
        return try await service.apply(edit)
    }
}
