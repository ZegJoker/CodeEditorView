import Foundation
import CodeEditorCore
import CodeEditorDocuments

public struct RestoredTab: Codable, Sendable, Hashable {
    public var id: EditorTabID
    public var documentURI: DocumentURI
    public var isPreview: Bool
    public var isPinned: Bool
    public var selection: CodeEditorCore.TextRange?
    public var scrollY: Double?

    public init(
        id: EditorTabID,
        documentURI: DocumentURI,
        isPreview: Bool,
        isPinned: Bool,
        selection: CodeEditorCore.TextRange? = nil,
        scrollY: Double? = nil
    ) {
        self.id = id
        self.documentURI = documentURI
        self.isPreview = isPreview
        self.isPinned = isPinned
        self.selection = selection
        self.scrollY = scrollY
    }
}

public struct RestoredPane: Codable, Sendable, Hashable {
    public var id: EditorPaneID
    public var tabs: [RestoredTab]
    public var selectedTabID: EditorTabID?
    public var previewTabID: EditorTabID?

    public init(
        id: EditorPaneID,
        tabs: [RestoredTab],
        selectedTabID: EditorTabID?,
        previewTabID: EditorTabID?
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.previewTabID = previewTabID
    }
}

public struct WorkspaceRestorationState: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaceID: WorkspaceID
    public var roots: [WorkspaceRoot]
    public var layout: EditorLayoutNode
    public var panes: [RestoredPane]
    public var activePaneID: EditorPaneID?
    public var focusHistory: [EditorPaneID]
    public var navigation: [NavigationEntry]
    public var navigationIndex: Int

    public init(
        schemaVersion: Int = WorkspaceRestorationState.currentSchemaVersion,
        workspaceID: WorkspaceID,
        roots: [WorkspaceRoot],
        layout: EditorLayoutNode,
        panes: [RestoredPane],
        activePaneID: EditorPaneID?,
        focusHistory: [EditorPaneID],
        navigation: [NavigationEntry],
        navigationIndex: Int
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.roots = roots
        self.layout = layout
        self.panes = panes
        self.activePaneID = activePaneID
        self.focusHistory = focusHistory
        self.navigation = navigation
        self.navigationIndex = navigationIndex
    }
}

public enum WorkspaceRestorationError: Error, Sendable, Equatable {
    /// Unknown newer schema must not be clamped — that reinterprets fields incorrectly.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptPayload(String)
}

public enum WorkspaceRestoration {
    /// Migrate known older schemas. **Rejects** unknown future schemas (audit §8.9).
    public static func migrate(_ state: WorkspaceRestorationState) throws -> WorkspaceRestorationState {
        var state = state
        if state.schemaVersion > WorkspaceRestorationState.currentSchemaVersion {
            throw WorkspaceRestorationError.unsupportedSchemaVersion(
                found: state.schemaVersion,
                supported: WorkspaceRestorationState.currentSchemaVersion
            )
        }
        if state.schemaVersion < 1 {
            // Oldest known baseline is v1; anything older is corrupt/unsupported.
            throw WorkspaceRestorationError.unsupportedSchemaVersion(
                found: state.schemaVersion,
                supported: WorkspaceRestorationState.currentSchemaVersion
            )
        }
        // v1 is baseline; future versions migrate stepwise here.
        return state
    }

    @MainActor
    public static func encode(_ workspace: Workspace) throws -> Data {
        let state = workspace.captureRestorationState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    public static func decode(_ data: Data) throws -> WorkspaceRestorationState {
        let decoder = JSONDecoder()
        let state = try decoder.decode(WorkspaceRestorationState.self, from: data)
        return try migrate(state)
    }
}
