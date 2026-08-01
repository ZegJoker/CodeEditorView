import Testing
import CodeEditorView
import CodeEditorLanguageSwift

@Suite("CodeEditorMacExample host")
struct HostTests {
    @Test func languagePackRegisters() throws {
        // Static initializer or first register may already have run.
        _ = try CodeEditorLanguageSwift.register()
        #expect(CodeEditorLanguageSwift.lastError == nil)
    }

    @Test func editorConfigurationDefaults() {
        let config = EditorConfiguration(
            appearance: .init(theme: .default, wrapLines: true),
            behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
            peripherals: .init(showGutter: true, showMinimap: false)
        )
        #expect(config.behavior.isEditable)
        #expect(config.peripherals.showGutter)
    }

    @Test @MainActor
    func editorControllerConstructs() {
        let controller = EditorController(text: "let x = 1\n")
        let text = controller.document.string
        #expect(text.contains("let"))
    }
}
