import Testing
import CodeEditorView
import CodeEditorLanguageSwift
@testable import CodeEditoriOSExample

@Suite("CodeEditoriOSExample host")
struct HostTests {
    @Test func languagePackRegisters() throws {
        _ = try CodeEditorLanguageSwift.register()
        #expect(CodeEditorLanguageSwift.lastError == nil)
    }

    @Test @MainActor
    func rootViewConstructs() {
        _ = CodeEditoriOSExampleRoot()
    }

    @Test func editorConfigurationDefaults() {
        let config = EditorConfiguration(
            appearance: .init(theme: .default, wrapLines: true),
            behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
            peripherals: .init(showGutter: true, showMinimap: false)
        )
        #expect(config.behavior.isEditable)
    }

    @Test @MainActor
    func editorControllerConstructs() {
        let controller = EditorController(text: "let x = 1\n")
        #expect(controller.document.string.contains("let"))
    }
}
