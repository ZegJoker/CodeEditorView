import SwiftUI
import CodeEditorView
import CodeEditorLanguageSwift

/// Phase 1 iOS example host — SwiftUI + UIKitEditorView path under Xcode 26.
public struct CodeEditoriOSExampleRoot: View {
    @State private var text = """
    import Foundation

    func hello() {
        print("CodeEditoriOSExample")
    }
    """
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorState = EditorState()

    public init() {
        do {
            _ = try CodeEditorLanguageSwift.register()
        } catch {
            assertionFailure("Language pack registration failed: \(error)")
        }
    }

    public var body: some View {
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
    }
}

/// App entry for Xcode app target / future @main wrapper.
public enum CodeEditoriOSExampleBootstrap {
    @MainActor
    public static func makeRootView() -> some View {
        CodeEditoriOSExampleRoot()
    }
}
