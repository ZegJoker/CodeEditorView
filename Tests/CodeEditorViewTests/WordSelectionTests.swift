import Testing
import Foundation
@testable import CodeEditorView

@Suite("Word selection")
struct WordSelectionTests {
    @Test func selectsIdentifier() {
        let doc = "func greet(_ name: String) {}"
        // offset inside "greet"
        let range = WordSelection.range(atUTF16Offset: 7, in: doc)
        #expect((doc as NSString).substring(with: range) == "greet")
    }

    @Test func selectsWordAtBoundaryAfterWord() {
        let doc = "hello world"
        // caret after "hello"
        let range = WordSelection.range(atUTF16Offset: 5, in: doc)
        #expect((doc as NSString).substring(with: range) == "hello")
    }

    @Test func underscoreInIdentifier() {
        let doc = "foo_bar baz"
        let range = WordSelection.range(atUTF16Offset: 3, in: doc)
        #expect((doc as NSString).substring(with: range) == "foo_bar")
    }

    @Test func punctuationSelectsSingleChar() {
        let doc = "a(b)"
        let range = WordSelection.range(atUTF16Offset: 1, in: doc)
        #expect((doc as NSString).substring(with: range) == "(")
    }
}

@Suite("Find panel focus helpers")
@MainActor
struct FindPanelFocusTests {
    @Test func showFindBumpsFocusTokenAndSelectsExistingQuery() {
        let controller = EditorController(text: "hello world hello")
        controller.setFindQuery("hello")
        let tokenBefore = controller.findSession.fieldFocusToken
        controller.showFindPanel(mode: .find)
        #expect(controller.findSession.isShowing)
        #expect(controller.findSession.fieldFocusToken == tokenBefore + 1)
        #expect(controller.findSession.fieldFocusTarget == .find)
        #expect(controller.findSession.selectFieldTextOnFocus == true)
    }

    @Test func showReplaceExpandsModeAndFocusesReplaceField() {
        let controller = EditorController(text: "abc")
        controller.showFindPanel(mode: .find)
        #expect(controller.findSession.mode == .find)
        #expect(controller.findSession.fieldFocusTarget == .find)
        let token = controller.findSession.fieldFocusToken
        controller.setReplaceText("xyz")
        controller.showReplacePanel()
        #expect(controller.findSession.mode == .replace)
        #expect(controller.findSession.isShowing)
        #expect(controller.findSession.fieldFocusToken == token + 1)
        #expect(controller.findSession.fieldFocusTarget == .replace)
        #expect(controller.findSession.selectFieldTextOnFocus == true)
    }

    @Test func showReplaceWithEmptyReplacementStillFocusesReplaceField() {
        let controller = EditorController(text: "abc")
        controller.showReplacePanel()
        #expect(controller.findSession.mode == .replace)
        #expect(controller.findSession.fieldFocusTarget == .replace)
        #expect(controller.findSession.selectFieldTextOnFocus == false)
    }
}
