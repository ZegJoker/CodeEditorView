import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Observable snapshot of focus / document / trust for command enablement (CMD-003 / audit §9.5).
///
/// Built from the real responder chain, workbench part, editor state, and workspace trust —
/// never fabricated as always-editable / always-focused.
public struct CommandContextSnapshot: Sendable, Hashable {
    public var activePart: String
    public var documentURI: DocumentURI?
    public var documentID: DocumentID?
    public var sessionID: EditorSessionID?
    public var languageID: String?
    public var isEditable: Bool
    public var isFocused: Bool
    public var isDirty: Bool
    public var hasSelection: Bool
    public var hasDocument: Bool
    public var workspaceTrust: String
    public var isDebugActive: Bool
    public var isTaskRunning: Bool
    public var flags: [String: Bool]
    public var selections: [CodeEditorCore.TextRange]

    public init(
        activePart: String = "editor",
        documentURI: DocumentURI? = nil,
        documentID: DocumentID? = nil,
        sessionID: EditorSessionID? = nil,
        languageID: String? = nil,
        isEditable: Bool = false,
        isFocused: Bool = false,
        isDirty: Bool = false,
        hasSelection: Bool = false,
        hasDocument: Bool = false,
        workspaceTrust: String = "restricted",
        isDebugActive: Bool = false,
        isTaskRunning: Bool = false,
        flags: [String: Bool] = [:],
        selections: [CodeEditorCore.TextRange] = []
    ) {
        self.activePart = activePart
        self.documentURI = documentURI
        self.documentID = documentID
        self.sessionID = sessionID
        self.languageID = languageID
        self.isEditable = isEditable
        self.isFocused = isFocused
        self.isDirty = isDirty
        self.hasSelection = hasSelection
        self.hasDocument = hasDocument
        self.workspaceTrust = workspaceTrust
        self.isDebugActive = isDebugActive
        self.isTaskRunning = isTaskRunning
        self.flags = flags
        self.selections = selections
    }

    public var evaluationInput: ContextEvaluationInput {
        var merged = flags
        merged["workspaceTrusted"] = workspaceTrust == "trusted"
        merged["workspaceRestricted"] = workspaceTrust == "restricted" || workspaceTrust == "untrusted"
        merged["debugActive"] = isDebugActive
        merged["taskRunning"] = isTaskRunning
        merged["documentDirty"] = isDirty
        merged["activePart.\(activePart)"] = true
        return ContextEvaluationInput(
            isEditable: isEditable,
            isFocused: isFocused,
            hasSelection: hasSelection,
            hasDocument: hasDocument,
            languageID: languageID,
            flags: merged
        )
    }

    /// Empty / unfocused default — fail-closed for enablement.
    public static let empty = CommandContextSnapshot()
}

extension CommandContext {
    /// Build a command context from a real snapshot plus an editor client.
    public static func make(
        from editor: any EditorCommandClient,
        snapshot: CommandContextSnapshot,
        services: CommandServiceLocator = CommandServiceLocator(),
        dependencies: CommandDependencies = CommandDependencies()
    ) -> CommandContext {
        CommandContext(
            documentID: snapshot.documentID ?? editor.documentID,
            sessionID: snapshot.sessionID ?? editor.sessionID,
            documentSnapshot: editor.snapshot,
            selections: snapshot.selections.isEmpty ? editor.selections : snapshot.selections,
            languageID: snapshot.languageID ?? editor.languageID,
            isEditable: snapshot.isEditable,
            isFocused: snapshot.isFocused,
            services: services,
            dependencies: dependencies,
            editor: editor
        )
    }
}
