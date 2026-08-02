import Foundation
import Testing

@testable import CodeEditorView

@Suite("Brace enter and delete")
@MainActor
struct BraceEnterDeleteTests {
    @Test func enterBetweenBracesDoesNotIndentCloser() {
        let controller = EditorController(text: "func f() {}")
        // Caret between { and }
        let open = (controller.text as NSString).range(of: "{").location
        controller.setSelectedRange(NSRange(location: open + 1, length: 0))
        controller.insertNewline()
        // func f() {\n    \n}
        #expect(controller.text == "func f() {\n    \n}")
        let lines = controller.text.split(separator: "\n", omittingEmptySubsequences: false)
        let closerLine = lines.last(where: { $0.contains("}") }) ?? ""
        #expect(closerLine == "}", "closer should not be indented, got \(closerLine.debugDescription)")
        // Caret on the middle (indented) line
        #expect(controller.selectedRange.location == "func f() {\n    ".utf16.count)
    }

    @Test func enterAfterTypedBracesGoodTest() {
        // Matches user report: type signature with auto-paired braces, then Enter.
        let controller = EditorController(text: "")
        controller.insertText("func goodTest(test: String) ")
        controller.insertText("{")
        #expect(controller.text.hasSuffix("{}"))
        #expect(controller.selectedRange.location == controller.text.utf16.count - 1)
        controller.insertNewline()
        #expect(controller.text == "func goodTest(test: String) {\n    \n}")
        let closer = controller.text.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        #expect(closer == "}")
    }

    @Test func deleteAtStartOfLineJoinsWithPrevious() {
        let controller = EditorController(text: "func f() {\n}")
        // Caret at start of line with }
        let close = (controller.text as NSString).range(of: "\n}").location + 1
        controller.setSelectedRange(NSRange(location: close, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "func f() {}")
    }

    @Test func deleteSpacesThenNewlineBeforeCloser() {
        let controller = EditorController(text: "func f() {\n    }")
        // Caret after the 4 spaces, before }
        let close = (controller.text as NSString).range(of: "}").location
        controller.setSelectedRange(NSRange(location: close, length: 0))
        // CESE DeleteWhitespaceFilter: one delete removes a full indent unit (4 spaces).
        controller.deleteBackward()
        #expect(controller.text == "func f() {\n}")
        #expect(TextFilters.isAtLineStart(location: controller.selectedRange.location, in: controller.text))
        controller.deleteBackward()
        #expect(controller.text == "func f() {}")
    }

    @Test func deleteAtColumnZeroAfterEnterBetweenBraces() {
        let controller = EditorController(text: "func f() {}")
        let open = (controller.text as NSString).range(of: "{").location
        controller.setSelectedRange(NSRange(location: open + 1, length: 0))
        controller.insertNewline()
        #expect(controller.text == "func f() {\n    \n}")
        // CESE: one delete in leading indent removes the whole indent unit.
        controller.deleteBackward()
        #expect(controller.text == "func f() {\n\n}")
        // Column 0 of blank line — CESE deletes the *previous* `\n` (join), caret stays on the open line.
        let caretBefore = controller.selectedRange.location
        #expect(TextFilters.isAtLineStart(location: caretBefore, in: controller.text))
        controller.deleteBackward()
        #expect(controller.text == "func f() {\n}")
        #expect(controller.text.contains("{"), "opening brace must survive blank-line delete")
        // Caret must NOT jump to column 0 of `}` — it stays after `{`.
        let openEnd = (controller.text as NSString).range(of: "{").location + 1
        #expect(
            controller.selectedRange.location == openEnd,
            "caret should remain after '{{', got \(controller.selectedRange.location)")
        // One more delete at that caret (now between { and \n) removes nothing useful from middle...
        // Move to column 0 of `}` and join.
        let closer = (controller.text as NSString).range(of: "}").location
        controller.setSelectedRange(NSRange(location: closer, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "func f() {}")
    }

    @Test func deleteBlankLineDoesNotEatOpeningBrace() {
        // Matches screenshot: signature, blank line, lone `}`.
        let controller = EditorController(text: "private func welcome(name: String) {\n\n}")
        // Caret on the blank line (between the two newlines).
        let blank = (controller.text as NSString).range(of: "{\n\n}").location + 2
        controller.setSelectedRange(NSRange(location: blank, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "private func welcome(name: String) {\n}")
        #expect(controller.text.contains("{"), "opening brace must survive blank-line delete")
        // CESE: caret lands after `{`, not on `}`.
        let afterOpen = (controller.text as NSString).range(of: "{").location + 1
        #expect(controller.selectedRange.location == afterOpen)
        // Column 0 of closer joins.
        let closer = (controller.text as NSString).range(of: "}").location
        controller.setSelectedRange(NSRange(location: closer, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "private func welcome(name: String) {}")
    }

    @Test func deleteAtColumnZeroOfWhitespaceLineJoinsLikeCESE() {
        // CESE/CETV: at col 0 of a whitespace-only line, Delete removes the previous line ending
        // (joins the spaces onto the previous line) — it does NOT nuke the whole blank line.
        let controller = EditorController(text: "a\n    \nb\n")
        let loc = (controller.text as NSString).range(of: "\n    \n").location + 1
        controller.setSelectedRange(NSRange(location: loc, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "a    \nb\n")
    }
}
