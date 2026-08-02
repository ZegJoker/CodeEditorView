import CodeEditorCommands
import Foundation

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
    ) throws -> any CommandDisposable {
        let tokens = [
            try registry.register(
                EditorCommand(id: refresh, title: "SCM: Refresh", category: .general) { _ in onRefresh() }),
            try registry.register(
                EditorCommand(id: stage, title: "SCM: Stage", category: .general) { _ in onStage() }),
            try registry.register(
                EditorCommand(id: commit, title: "SCM: Commit", category: .general) { _ in onCommit() }),
        ]
        return RegistrationToken {
            for token in tokens {
                token.dispose()
            }
        }
    }
}