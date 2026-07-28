import Testing
import Foundation
@testable import CodeEditorView

@Suite("LayoutInvalidation")
struct LayoutInvalidationTests {
    @Test func splitLinesKeepsTerminators() {
        let metrics = LayoutInvalidation.splitLines(in: "a\nb\n", estimatedHeight: 10)
        #expect(metrics.count == 3)
        #expect(metrics[0].utf16Length == 2)
        #expect(metrics[1].utf16Length == 2)
        #expect(metrics[2].utf16Length == 0)
    }

    @Test func localizedEditPreservesDocumentLength() async {
        await MainActor.run {
            let controller = EditorController(text: "line1\nline2\nline3\nline4")
            let before = controller.layout.lineIndex.count
            controller.setSelectedRange(NSRange(location: 6, length: 5)) // "line2"
            controller.insertText("XX")
            #expect(controller.layout.lineIndex.length == controller.document.length)
            #expect(controller.layout.lineIndex.count >= before - 1)
            #expect(controller.text.contains("XX"))
        }
    }
}
