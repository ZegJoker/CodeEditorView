import SwiftUI
import CodeEditorView
import CodeEditorLanguageSwift

/// Small composition: editor UI + single language pack (no workspace/workbench).
@main
struct SmallEditorApp: App {
    init() {
        try? CodeEditorLanguageSwift.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var text = """
    func hello() {
        print("small editor")
    }
    """
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorState = EditorState()

    var body: some View {
        CodeEditor(
            text: $text,
            selection: $selection,
            editorState: $editorState,
            configuration: EditorConfiguration(
                appearance: .init(theme: .default, wrapLines: true),
                behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            language: .swift
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}
