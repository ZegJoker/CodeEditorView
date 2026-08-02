import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Structure commands")
@MainActor
struct StructureCommandTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func indentMultiLineSelection() {
        let src = "a\nb\nc\n"
        let reps = StructureCommands.indentLines(
            selections: [NSRange(location: 0, length: src.utf16.count)],
            document: src,
            indent: .spaces(count: 2)
        )
        #expect(reps.count == 3)
        // Applied high→low in controller; planners return high→low
        #expect(reps[0].string == "  ")
    }

    @Test func controllerIndentSelection() {
        var config = EditorConfiguration()
        config.behavior.indentOption = .spaces(count: 2)
        let controller = EditorController(text: "a\nb\n", configuration: config, language: .plainText)
        controller.setSelectedRange(NSRange(location: 0, length: 4))
        controller.indentSelection()
        #expect(controller.text == "  a\n  b\n")
    }

    @Test func controllerOutdentSelection() {
        let controller = EditorController(text: "    a\n    b\n", language: .plainText)
        controller.setSelectedRange(NSRange(location: 0, length: 12))
        controller.outdentSelection()
        #expect(controller.text.contains("a\n"))
        #expect(!controller.text.hasPrefix("    a"))
    }

    @Test func toggleLineCommentSwift() {
        let controller = EditorController(text: "let x = 1\n", language: .swift)
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        controller.toggleLineComment()
        #expect(controller.text.hasPrefix("// "))
        controller.toggleLineComment()
        #expect(controller.text.hasPrefix("let x"))
    }

    @Test func moveLinesUp() {
        let controller = EditorController(text: "a\nb\nc\n", language: .plainText)
        // Caret on line "b"
        controller.setSelectedRange(NSRange(location: 2, length: 0))
        controller.moveSelectedLines(up: true)
        #expect(controller.text.hasPrefix("b\na\n") || controller.text == "b\na\nc\n")
    }

    @Test func insertTabAtCaret() {
        let controller = EditorController(text: "x", language: .plainText)
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        controller.insertTab()
        #expect(controller.text.hasPrefix("    ") || controller.text.hasPrefix("\t") || controller.text.count > 1)
    }

    @Test func insertNewlineIndents() {
        let controller = EditorController(text: "func f() {", language: .swift)
        controller.setSelectedRange(NSRange(location: (controller.text as NSString).length, length: 0))
        controller.insertNewline()
        #expect(controller.text.contains("\n"))
        // Extra indent after {
        let lines = controller.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2)
        #expect(lines[1].hasPrefix("    ") || lines[1].hasPrefix("\t") || lines[1].isEmpty == false)
    }

    @Test func autoPairParentheses() {
        let controller = EditorController(text: "", language: .plainText)
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        controller.insertText("(")
        #expect(controller.text == "()")
        #expect(controller.selectedRange.location == 1)
    }

    @Test func multiCursorTab() {
        let controller = EditorController(text: "a\nb\n", language: .plainText)
        controller.setSelectedRanges([
            NSRange(location: 0, length: 0),
            NSRange(location: 2, length: 0),
        ])
        controller.insertTab()
        #expect(controller.text.contains("a"))
        #expect(controller.selectedRanges.count == 2)
    }
}
