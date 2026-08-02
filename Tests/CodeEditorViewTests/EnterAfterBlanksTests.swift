import Foundation
import Testing

@testable import CodeEditorView

@Suite("Enter after blank lines")
@MainActor
struct EnterAfterBlanksTests {
    @Test func firstEnterAtEOFCreatesVisibleNewLine() {
        // User report: many blank lines, type chars, first Enter only bumps column
        // (no line break) because localized layout omitted the trailing caret row.
        var text = "start\n"
        for _ in 0..<80 { text += "\n" }
        text += "abc"
        let controller = EditorController(text: text)
        let end = controller.text.utf16.count
        controller.setSelectedRange(NSRange(location: end, length: 0))

        let lineBefore = controller.cursorPositions.first?.line ?? -1
        let colBefore = controller.cursorPositions.first?.column ?? -1
        controller.insertNewline()

        #expect(controller.text.hasSuffix("abc\n"))
        #expect(controller.layout.lineIndex.length == controller.document.length)

        // Full rebuild would have a trailing empty line after the final `\n`.
        let last = controller.layout.lineIndex.last
        #expect(last != nil)
        #expect(last?.metrics.utf16Length == 0, "trailing caret line required after EOF newline")

        let pos = controller.cursorPositions.first
        #expect(pos != nil)
        // New line (not same line with column+1 for the terminator).
        #expect((pos?.line ?? -1) > lineBefore)
        #expect(
            pos?.column == 0,
            "caret should be at column 0 of the new line, got \(pos?.column ?? -1); before col=\(colBefore)")
    }

    @Test func secondEnterAlsoWorks() {
        let controller = EditorController(text: "abc")
        controller.setSelectedRange(NSRange(location: 3, length: 0))
        controller.insertNewline()
        controller.insertNewline()
        #expect(controller.text == "abc\n\n")
        #expect(controller.layout.lineIndex.length == controller.document.length)
        #expect(controller.layout.lineIndex.last?.metrics.utf16Length == 0)
        #expect(controller.cursorPositions.first?.column == 0)
    }

    @Test func enterAfterBlanksCharsViaInsertTextPath() {
        var text = ""
        for _ in 0..<50 { text += "\n" }
        text += "xy"
        let controller = EditorController(text: text)
        controller.setSelectedRange(NSRange(location: controller.text.utf16.count, length: 0))
        let lineBefore = controller.cursorPositions.first?.line ?? 0
        // AppKit sometimes routes Return as insertText("\n") — still needs trailing caret line.
        controller.insertText("\n")
        #expect(controller.layout.lineIndex.length == controller.document.length)
        #expect(controller.layout.lineIndex.last?.metrics.utf16Length == 0)
        #expect((controller.cursorPositions.first?.line ?? 0) > lineBefore)
        #expect(controller.cursorPositions.first?.column == 0)
    }

    @Test func manyBlankLinesThenCharsThenEnter() {
        var text = "a"
        for _ in 0..<200 { text += "\n" }
        text += "z"
        let controller = EditorController(text: text)
        controller.setSelectedRange(NSRange(location: controller.text.utf16.count, length: 0))
        controller.insertText("1")
        let lineBefore = controller.cursorPositions.first?.line ?? 0
        controller.insertNewline()
        controller.insertText("2")
        #expect(controller.layout.lineIndex.length == controller.document.length)
        #expect(controller.text.hasSuffix("z1\n2"))
        #expect((controller.cursorPositions.first?.line ?? 0) > lineBefore)
    }

    @Test func midDocumentEnterDoesNotInventPhantomBlank() {
        let controller = EditorController(text: "hello\nworld\n")
        let linesBefore = controller.layout.lineIndex.count
        // Caret after "hello" (before its newline)
        controller.setSelectedRange(NSRange(location: 5, length: 0))
        controller.insertNewline()
        #expect(controller.text == "hello\n\nworld\n")
        // One new content line (empty between hello and world); trailing empty still one.
        #expect(controller.layout.lineIndex.count == linesBefore + 1)
        #expect(controller.layout.lineIndex.length == controller.document.length)
    }
}
