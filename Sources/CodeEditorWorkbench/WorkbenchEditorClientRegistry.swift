import CodeEditorCommands
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Tracks command clients for open editor sessions (text views).
@MainActor
public final class WorkbenchEditorClientRegistry {
    private var clients: [EditorSessionID: any EditorCommandClient] = [:]

    public init() {}

    public func register(sessionID: EditorSessionID, client: any EditorCommandClient) {
        clients[sessionID] = client
    }

    public func unregister(sessionID: EditorSessionID) {
        clients[sessionID] = nil
    }

    public func client(for sessionID: EditorSessionID) -> (any EditorCommandClient)? {
        clients[sessionID]
    }

    public func activeClient(workspace: Workspace) -> (any EditorCommandClient)? {
        guard let paneID = workspace.activePaneID,
            let pane = workspace.panes[paneID],
            let tab = pane.selectedTab
        else { return nil }
        return clients[tab.sessionID]
    }
}
