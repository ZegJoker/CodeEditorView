import SwiftUI
import CodeEditorView
import CodeEditorLanguageSwift

/// Phase 1 macOS example host — real AppKit/SwiftUI editor surface under Xcode 26.
@main
struct CodeEditorMacExampleApp: App {
    init() {
        do {
            _ = try CodeEditorLanguageSwift.register()
        } catch {
            assertionFailure("Language pack registration failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var text = """
    import Foundation

    func hello() {
        print("CodeEditorMacExample")
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
        .frame(minWidth: 640, minHeight: 420)
    }
}
