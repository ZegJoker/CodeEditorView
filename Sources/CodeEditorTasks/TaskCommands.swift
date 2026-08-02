import CodeEditorCommands
import Foundation

public enum TaskCommands {
    public static let run = CommandID(stringLiteral: "codeeditor.tasks.run")
    public static let cancel = CommandID(stringLiteral: "codeeditor.tasks.cancel")

    @MainActor
    @discardableResult
    public static func register(
        into registry: CommandRegistry,
        onRun: @escaping @MainActor () -> Void = {},
        onCancel: @escaping @MainActor () -> Void = {}
    ) throws -> any CommandDisposable {
        let t1 = try registry.register(
            EditorCommand(id: run, title: "Run Task", category: .general) { _ in onRun() }
        )
        let t2 = try registry.register(
            EditorCommand(id: cancel, title: "Cancel Task", category: .general) { _ in onCancel() }
        )
        return RegistrationToken {
            t1.dispose()
            t2.dispose()
        }
    }
}
