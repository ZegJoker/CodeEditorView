import Testing
import Foundation
@testable import CodeEditorView

@Suite("Multi-cursor edits")
struct MultiCursorEditTests {
    @Test func multiCursorInsert() async {
        await MainActor.run {
            let controller = EditorController(text: "abcdef")
            controller.setSelectedRanges([
                NSRange(location: 1, length: 0),
                NSRange(location: 4, length: 0),
            ])
            controller.insertText("X")
            #expect(controller.text == "aXbcdXef")
            #expect(controller.selectedRanges.count == 2)
        }
    }

    @Test func multiCursorDeleteBackward() async {
        await MainActor.run {
            let controller = EditorController(text: "abcdef")
            controller.setSelectedRanges([
                NSRange(location: 2, length: 0),
                NSRange(location: 5, length: 0),
            ])
            controller.deleteBackward()
            #expect(controller.text == "acdf")
        }
    }
}
