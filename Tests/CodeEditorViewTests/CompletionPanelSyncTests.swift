import Foundation
import Testing
@testable import CodeEditorView

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
private final class ReproCompletionDelegate: CodeSuggestionDelegate {
    let catalog: [SimpleCodeSuggestion] = [
        SimpleCodeSuggestion(label: "greet", detail: "func", systemImage: "function"),
        SimpleCodeSuggestion(label: "print", detail: "func", systemImage: "function"),
        SimpleCodeSuggestion(label: "return", detail: "keyword", systemImage: "k.square"),
        SimpleCodeSuggestion(label: "String", detail: "struct", systemImage: "s.square"),
        SimpleCodeSuggestion(label: "name", detail: "param", systemImage: "p.square"),
    ]

    func completionTriggerCharacters() -> Set<String> { ["."] }

    func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        (cursorPosition, catalog)
    }

    func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        catalog
    }

    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    ) {}
}

@Suite("Completion panel sync")
@MainActor
struct CompletionPanelSyncTests {
    @Test func syncWhileSelectingSameRowIsStable() {
        let controller = EditorController(text: "x", configuration: .init())
        controller.completionDelegate = ReproCompletionDelegate()
        let editor = AppKitEditorView(controller: controller)
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let panel = AppKitCompletionPanelController()
        panel.attach(controller: controller, editorView: editor)

        controller.completionSession.setItems(
            [
                SimpleCodeSuggestion(label: "one"),
                SimpleCodeSuggestion(label: "two"),
            ],
            anchor: CursorPosition(range: NSRange(location: 1, length: 0), line: 0, column: 1)
        )
        // Hammer notify — previously could recurse via table selection.
        for _ in 0..<200 {
            controller.notifyCompletionSessionChange()
        }
        // Typing path while session is open.
        for ch in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"] {
            controller.insertText(ch)
            controller.notifyCompletionSessionChange()
        }
        panel.detach()
        // Survived without stack overflow; document still contains original text.
        #expect(controller.text.contains("x"))
        #expect(controller.text.count >= 1)
    }

    @Test func insertLetterOpensCompletionsWithoutHang() async {
        let controller = EditorController(text: "", configuration: .init())
        controller.completionDelegate = ReproCompletionDelegate()
        let editor = AppKitEditorView(controller: controller)
        editor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let panel = AppKitCompletionPanelController()
        panel.attach(controller: controller, editorView: editor)

        controller.insertText("p")
        // showCompletions is async — wait for items.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(25))
            if controller.completionSession.isVisible { break }
        }
        controller.insertText("r")
        controller.insertText("i")
        for _ in 0..<20 {
            controller.notifyCompletionSessionChange()
        }
        panel.detach()
        #expect(controller.text == "pri")
    }
}
#endif
