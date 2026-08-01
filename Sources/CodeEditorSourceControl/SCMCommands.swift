import Foundation
import CodeEditorCommands

public enum SCMCommands {
    public static let refresh = CommandID(stringLiteral: "codeeditor.scm.refresh")
    public static let stage = CommandID(stringLiteral: "codeeditor.scm.stage")
    public static let commit = CommandID(stringLiteral: "codeeditor.scm.commit")

    @MainActor
    @discardableResult
    public static func register(
        into registry: CommandRegistry,
        onRefresh: @escaping @MainActor () -> Void = {},
        onStage: @escaping @MainActor () -> Void = {},
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> any CommandDisposable {
        let tokens = [
            registry.register(EditorCommand(id: refresh, title: "SCM: Refresh", category: .general) { _ in onRefresh() }),
            registry.register(EditorCommand(id: stage, title: "SCM: Stage", category: .general) { _ in onStage() }),
            registry.register(EditorCommand(id: commit, title: "SCM: Commit", category: .general) { _ in onCommit() }),
        ]
        return RegistrationToken {
            tokens.forEach { $0.dispose() }
        }
    }
}
