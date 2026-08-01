import CodeEditorCommands
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Built-in commands")
@MainActor
struct BuiltInCommandTests {
    @Test func indentViaCommandID() throws {
        let controller = EditorController(text: "hello")
        controller.setSelectedRange(NSRange(location: 0, length: 5))
        try controller.executeCommand(BuiltInCommandID.indent)
        #expect(controller.text.hasPrefix(" ") || controller.text.hasPrefix("\t") || controller.text != "hello")
    }

    @Test func undoViaCommandID() throws {
        let controller = EditorController(text: "a")
        controller.setSelectedRange(NSRange(location: 1, length: 0))
        controller.insertText("b")
        #expect(controller.text == "ab")
        try controller.executeCommand(BuiltInCommandID.undo)
        #expect(controller.text == "a")
    }

    @Test func findShowViaCommandID() throws {
        let controller = EditorController(text: "x")
        #expect(!controller.findSession.isShowing)
        try controller.executeCommand(BuiltInCommandID.findShow)
        #expect(controller.findSession.isShowing)
    }

    @Test func keyPressIndentViaDispatcher() throws {
        let controller = EditorController(text: "line")
        controller.setSelectedRange(NSRange(location: 0, length: 4))
        let dispatcher = try #require(controller.commandDispatcher)
        let press = KeyPress(key: "]", modifiers: .command)
        let consumed = try dispatcher.handleKeyPress(press, context: controller.makeCommandContext())
        #expect(consumed)
        #expect(controller.text != "line")
    }
}
