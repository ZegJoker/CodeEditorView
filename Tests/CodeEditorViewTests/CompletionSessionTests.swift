import Testing
import Foundation
@testable import CodeEditorView

@MainActor
private final class MockCompletionDelegate: CodeSuggestionDelegate {
    var requests = 0
    var moveCount = 0
    var applied: String?
    var items: [SimpleCodeSuggestion] = [
        SimpleCodeSuggestion(label: "greet", detail: "func", systemImage: "function"),
        SimpleCodeSuggestion(label: "green", detail: "var", systemImage: "v.square"),
        SimpleCodeSuggestion(label: "group", detail: "type", systemImage: "t.square"),
    ]

    func completionTriggerCharacters() -> Set<String> { ["."] }

    func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        requests += 1
        return (cursorPosition, items)
    }

    func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        moveCount += 1
        let prefix = Self.prefix(at: cursorPosition, in: textView.text)
        // Empty prefix must dismiss — `hasPrefix("")` matches every label.
        guard !prefix.isEmpty else { return nil }
        let filtered = items.filter { $0.label.hasPrefix(prefix) }
        return filtered.isEmpty ? nil : filtered
    }

    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    ) {
        applied = item.label
        guard let cursorPosition else {
            textView.insertText(item.label)
            return
        }
        // Replace identifier prefix before caret.
        let loc = cursorPosition.range.location
        let prefix = Self.prefix(at: cursorPosition, in: textView.text)
        let start = loc - prefix.utf16.count
        textView.replaceCharacters(
            in: NSRange(location: max(0, start), length: prefix.utf16.count),
            with: item.label
        )
    }

    static func prefix(at cursor: CursorPosition, in text: String) -> String {
        let ns = text as NSString
        var i = cursor.range.location
        var chars: [Character] = []
        while i > 0 {
            let ch = ns.substring(with: NSRange(location: i - 1, length: 1))
            guard let c = ch.first, c.isLetter || c.isNumber || c == "_" else { break }
            chars.insert(c, at: 0)
            i -= 1
        }
        return String(chars)
    }
}

@Suite("Completion session")
@MainActor
struct CompletionSessionTests {
    @Test func showLoadsItemsFromDelegate() async {
        let controller = EditorController(text: "func ")
        let mock = MockCompletionDelegate()
        controller.completionDelegate = mock
        controller.setSelectedRange(NSRange(location: controller.document.length, length: 0))
        controller.showCompletions()
        // Allow async task to finish.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.requests == 1)
        #expect(controller.completionsVisible)
        #expect(controller.completionSession.items.count == 3)
    }

    @Test func typingLetterTriggersShow() async {
        let controller = EditorController(text: "")
        let mock = MockCompletionDelegate()
        controller.completionDelegate = mock
        controller.insertText("g")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(mock.requests >= 1)
        #expect(controller.completionsVisible)
    }

    @Test func applyInsertsLabel() async {
        let controller = EditorController(text: "gr")
        let mock = MockCompletionDelegate()
        controller.completionDelegate = mock
        controller.setSelectedRange(NSRange(location: 2, length: 0))
        controller.showCompletions()
        try? await Task.sleep(for: .milliseconds(50))
        controller.selectCompletionIndex(0)
        controller.applyCompletionSelection()
        #expect(mock.applied == "greet")
        #expect(controller.text == "greet")
        #expect(!controller.completionsVisible)
    }

    @Test func hideClearsSession() async {
        let controller = EditorController(text: "x")
        let mock = MockCompletionDelegate()
        controller.completionDelegate = mock
        controller.showCompletions()
        try? await Task.sleep(for: .milliseconds(50))
        controller.hideCompletions()
        #expect(!controller.completionsVisible)
        #expect(controller.completionSession.items.isEmpty)
    }

    @Test func deletingTriggerCharacterDismissesCompletions() async {
        let controller = EditorController(text: "")
        let mock = MockCompletionDelegate()
        controller.completionDelegate = mock
        controller.insertText("g")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.completionsVisible)
        controller.deleteBackward()
        // Cursor-move filter with empty prefix must close (not show the full catalog).
        #expect(!controller.completionsVisible)
        #expect(controller.completionSession.items.isEmpty)
    }
}
