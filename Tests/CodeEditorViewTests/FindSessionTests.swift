import Testing
import Foundation
@testable import CodeEditorView

@Suite("Find session")
@MainActor
struct FindSessionTests {
    @Test func showSeedsFromSelectionAndFinds() {
        let controller = EditorController(text: "hello test world test")
        controller.setSelectedRange(NSRange(location: 6, length: 4)) // "test"
        controller.showFindPanel()
        #expect(controller.findSession.isShowing)
        #expect(controller.findSession.findText == "test")
        #expect(controller.findSession.matches.count == 2)
        #expect(controller.editorState.findPanelVisible == true)
        #expect(controller.editorState.findText == "test")
    }

    @Test func findNextWrapsWhenEnabled() {
        let controller = EditorController(text: "test1\ntest2\ntest3")
        controller.setFindQuery("test")
        controller.showFindPanel()
        controller.findSession.currentMatchIndex = 2
        controller.setWrapAround(true)
        controller.findNext()
        #expect(controller.findSession.currentMatchIndex == 0)
        controller.findPrevious()
        #expect(controller.findSession.currentMatchIndex == 2)
    }

    @Test func findNextStopsWhenWrapDisabled() {
        let controller = EditorController(text: "test1\ntest2\ntest3")
        controller.setFindQuery("test")
        controller.showFindPanel()
        controller.findSession.currentMatchIndex = 2
        controller.setWrapAround(false)
        controller.findNext()
        #expect(controller.findSession.currentMatchIndex == 2)
        controller.findSession.currentMatchIndex = 0
        controller.findPrevious()
        #expect(controller.findSession.currentMatchIndex == 0)
    }

    @Test func replaceCurrentShiftsLaterMatches() {
        let controller = EditorController(text: "aa aa aa")
        controller.setFindQuery("aa")
        controller.showFindPanel()
        #expect(controller.findSession.matches.count == 3)
        controller.findSession.currentMatchIndex = 0
        controller.setReplaceText("b")
        controller.replaceCurrentMatch()
        #expect(controller.text == "b aa aa")
        #expect(controller.findSession.matches.count == 2)
    }

    @Test func replaceGreetWithWelcomeKeepsSecondMatchAligned() {
        // Demo sample regression: replace first "greet" → "welcome"; next match must still be "greet".
        let src = """
        // Swift — CodeEditorView demo
        func greet(_ name: String) {
            print("Hello, \\(name)!")
        }

        greet("world")
        """
        let controller = EditorController(text: src)
        var mirrored = src
        controller.onTextDidChange = { mirrored = $0 }
        controller.setFindQuery("greet")
        controller.showFindPanel()
        #expect(controller.findSession.matches.count == 2)
        controller.findSession.currentMatchIndex = 0
        controller.setReplaceText("welcome")
        controller.replaceCurrentMatch()
        #expect(controller.text.contains("func welcome"))
        #expect(controller.text.contains("greet(\"world\")"))
        #expect(mirrored == controller.text, "host binding must receive replace result")
        #expect(controller.findSession.matches.count == 1)
        if let match = controller.findSession.currentMatch {
            let piece = (controller.text as NSString).substring(with: match)
            #expect(piece == "greet", "second match must remain 'greet', got \(piece.debugDescription)")
            #expect(controller.selectedRange == match)
        } else {
            Issue.record("expected a remaining match after replace")
        }
    }

    @Test func replaceAll() {
        let controller = EditorController(text: "test1\ntest2\ntest3")
        controller.setFindQuery("test")
        controller.showFindPanel()
        controller.setReplaceText("x")
        controller.replaceAllMatches()
        #expect(controller.text == "x1\nx2\nx3")
        #expect(controller.findSession.matches.isEmpty)
    }

    @Test func reFindAfterEdit() {
        let controller = EditorController(text: "foo bar foo")
        controller.setFindQuery("foo")
        controller.showFindPanel()
        #expect(controller.findSession.matches.count == 2)
        controller.setSelectedRange(NSRange(location: controller.text.utf16.count, length: 0))
        controller.insertText(" foo")
        #expect(controller.findSession.matches.count == 3)
    }

    @Test func hideClearsEmphases() {
        let controller = EditorController(text: "abc abc")
        controller.setFindQuery("abc")
        controller.showFindPanel()
        #expect(!controller.emphasis.items.filter { $0.group == EmphasisGroup.find }.isEmpty)
        controller.hideFindPanel()
        #expect(controller.emphasis.items.filter { $0.group == EmphasisGroup.find }.isEmpty)
        #expect(controller.findSession.isShowing == false)
    }

    @Test func matchCaseOnSession() {
        let controller = EditorController(text: "Test1\ntest2\nTEST3")
        controller.setFindQuery("Test")
        controller.showFindPanel()
        controller.setMatchCase(true)
        #expect(controller.findSession.matches.count == 1)
        controller.setMatchCase(false)
        #expect(controller.findSession.matches.count == 3)
    }
}
