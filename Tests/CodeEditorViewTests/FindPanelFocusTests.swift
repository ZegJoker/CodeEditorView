import Testing
import Foundation
@testable import CodeEditorView

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
