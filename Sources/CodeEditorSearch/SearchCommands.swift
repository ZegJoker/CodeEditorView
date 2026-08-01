import Foundation
import CodeEditorCommands

public enum SearchCommands {
    public static let findInFiles = CommandID(stringLiteral: "codeeditor.search.findInFiles")
    public static let replaceInFiles = CommandID(stringLiteral: "codeeditor.search.replaceInFiles")

    @MainActor
    @discardableResult
    public static func register(
        into registry: CommandRegistry,
        onFindInFiles: @escaping @MainActor () -> Void = {},
        onReplaceInFiles: @escaping @MainActor () -> Void = {}
    ) -> any CommandDisposable {
        let t1 = registry.register(
            EditorCommand(
                id: findInFiles,
                title: "Find in Files",
                category: .find
            ) { _ in
                onFindInFiles()
            }
        )
        let t2 = registry.register(
            EditorCommand(
                id: replaceInFiles,
                title: "Replace in Files",
                category: .find
            ) { _ in
                onReplaceInFiles()
            }
        )
        return RegistrationToken {
            t1.dispose()
            t2.dispose()
        }
    }
}
