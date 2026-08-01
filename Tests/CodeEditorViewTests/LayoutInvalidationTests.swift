import Foundation
import Testing

@testable import CodeEditorView

@Suite("LayoutInvalidation")
struct LayoutInvalidationTests {
    @Test func splitLinesFullDocumentTrailingEmpty() {
        let metrics = LayoutInvalidation.splitLines(
            in: "a\nb\n",
            estimatedHeight: 10,
            includeTrailingEmptyLine: true
        )
        #expect(metrics.count == 3)
        #expect(metrics[0].utf16Length == 2)
        #expect(metrics[1].utf16Length == 2)
        #expect(metrics[2].utf16Length == 0)
    }

    @Test func splitLinesLocalizedSliceDoesNotAddPhantomEmpty() {
        // Mid-document lines always end with \n; localized edits must not invent a blank row.
        let metrics = LayoutInvalidation.splitLines(
            in: "hello\n",
            estimatedHeight: 10,
            includeTrailingEmptyLine: false
        )
        #expect(metrics.count == 1)
        #expect(metrics[0].utf16Length == 6)
    }

    @Test func insertCharacterDoesNotAddBlankLine() async {
        await MainActor.run {
            let controller = EditorController(text: "hello\nworld\n")
            let linesBefore = controller.layout.lineIndex.count
            // Place caret after "hello" (before newline at index 5)
            controller.setSelectedRange(NSRange(location: 5, length: 0))
            controller.insertText("X")
            #expect(controller.text == "helloX\nworld\n")
            // Full rebuild would still have trailing empty → same count as before (3 lines: helloX, world, empty)
            // Must not grow by +1 phantom after the edited line.
            #expect(controller.layout.lineIndex.count == linesBefore)
            #expect(controller.layout.lineIndex.length == controller.document.length)
        }
    }

    @Test func enterAtEndOfFileAddsTrailingCaretLine() async {
        await MainActor.run {
            let controller = EditorController(text: "abc")
            #expect(controller.layout.lineIndex.count == 1)
            controller.setSelectedRange(NSRange(location: 3, length: 0))
            controller.insertNewline()
            #expect(controller.text == "abc\n")
            // "abc\n" + trailing empty caret line
            #expect(controller.layout.lineIndex.count == 2)
            #expect(controller.layout.lineIndex.last?.metrics.utf16Length == 0)
            #expect(controller.cursorPositions.first?.line == 1)
            #expect(controller.cursorPositions.first?.column == 0)
        }
    }

    @Test func localizedEditPreservesDocumentLength() async {
        await MainActor.run {
            let controller = EditorController(text: "line1\nline2\nline3\nline4")
            let before = controller.layout.lineIndex.count
            controller.setSelectedRange(NSRange(location: 6, length: 5))  // "line2"
            controller.insertText("XX")
            #expect(controller.layout.lineIndex.length == controller.document.length)
            #expect(controller.layout.lineIndex.count >= before - 1)
            #expect(controller.text.contains("XX"))
        }
    }

    @Test func deleteCharacterNoCrashAndStableLines() async {
        await MainActor.run {
            let controller = EditorController(text: "hello\nworld\n")
            controller.setSelectedRange(NSRange(location: 5, length: 0))
            controller.insertText("X")
            controller.setSelectedRange(NSRange(location: 6, length: 0))
            controller.deleteBackward()
            #expect(controller.text == "hello\nworld\n")
            #expect(controller.layout.lineIndex.length == controller.document.length)
            // Typeset/draw path must not throw
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 400, height: 400),
                containerWidth: 400
            )
        }
    }
}
