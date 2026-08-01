import CodeEditorCommands
import CodeEditorExtensionAPI
import Foundation

// ExtensionDisposable, ExtensionRegistrationToken, CompositeExtensionDisposable
// live in CodeEditorExtensionAPI. Host adapters:

extension ExtensionRegistrationToken {
    /// Adapts Commands ``CommandDisposable`` / ``RegistrationToken`` to extension disposal.
    public convenience init(wrapping commandDisposable: any CommandDisposable) {
        self.init {
            commandDisposable.dispose()
        }
    }
}
