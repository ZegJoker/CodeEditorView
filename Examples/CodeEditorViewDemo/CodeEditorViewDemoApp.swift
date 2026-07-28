import SwiftUI
import CodeEditorView

@main
struct CodeEditorViewDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}

struct DemoRootView: View {
    @State private var text = """
    // CodeEditorView demo
    func greet(_ name: String) {
        print("Hello, \\(name)!")
    }

    greet("world")
    """
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var wrapLines = true
    @State private var showInvisibles = false
    @State private var controller = EditorController(text: "")

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            CodeEditor(
                text: $text,
                selection: $selection,
                configuration: EditorConfiguration(
                    wrapLines: wrapLines,
                    showInvisibleCharacters: showInvisibles
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            controller = EditorController(text: text)
        }
    }

    private var toolbar: some View {
        HStack {
            Toggle("Wrap", isOn: $wrapLines)
            Toggle("Invisibles", isOn: $showInvisibles)
            Button("Add cursor @ end") {
                selection = NSRange(location: text.utf16.count, length: 0)
            }
            Button("Emphasize first line") {
                controller.text = text
                controller.emphasis.removeAll()
                if let end = text.firstIndex(of: "\n") {
                    let len = text.utf16.distance(from: text.startIndex, to: end)
                    controller.emphasis.add(
                        Emphasis(range: NSRange(location: 0, length: len), style: .outline, flash: true)
                    )
                }
            }
            Spacer()
            Text("\(text.split(separator: "\n").count) lines")
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
