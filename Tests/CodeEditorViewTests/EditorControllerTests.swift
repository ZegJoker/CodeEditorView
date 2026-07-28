import Testing
import Foundation
@testable import CodeEditorView

@Suite("EditorController")
@MainActor
struct EditorControllerTests {
    @Test func insertAndUndo() {
        let controller = EditorController(text: "abc")
        controller.setSelectedRange(NSRange(location: 3, length: 0))
        controller.insertText("d")
        #expect(controller.text == "abcd")
        #expect(controller.selectedRange.location == 4)

        controller.undo()
        #expect(controller.text == "abc")
    }

    @Test func replaceSelection() {
        let controller = EditorController(text: "hello")
        controller.setSelectedRange(NSRange(location: 0, length: 5))
        controller.insertText("yo")
        #expect(controller.text == "yo")
    }

    @Test func deleteBackward() {
        let controller = EditorController(text: "ab")
        controller.setSelectedRange(NSRange(location: 2, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "a")
    }

    @Test func layoutProducesFragments() {
        let controller = EditorController(text: "line1\nline2\nline3")
        let snapshot = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            containerWidth: 400
        )
        #expect(snapshot.fragments.isEmpty == false)
        #expect(snapshot.contentSize.height > 0)
    }

    @Test func hitTestAndCaret() {
        let controller = EditorController(text: "hello\nworld")
        let width: CGFloat = 300
        _ = controller.layoutViewport(visibleRect: CGRect(x: 0, y: 0, width: width, height: 200), containerWidth: width)
        let offset = controller.hitTestOffset(at: CGPoint(x: 10, y: 2), containerWidth: width)
        #expect(offset >= 0)
        let caret = controller.caretRect(containerWidth: width)
        #expect(caret != nil)
    }

    @Test func selectionMoveCharacter() {
        let controller = EditorController(text: "abcd")
        controller.setSelectedRange(NSRange(location: 2, length: 0))
        controller.move(direction: .right, containerWidth: 300)
        #expect(controller.selectedRange.location == 3)
        controller.move(direction: .left, containerWidth: 300)
        #expect(controller.selectedRange.location == 2)
    }

    @Test func eventStreamEmits() async {
        let controller = EditorController(text: "")
        let stream = controller.textChanges
        let task = Task {
            var values: [String] = []
            for await value in stream {
                values.append(value)
                if values.count >= 1 { break }
            }
            return values
        }
        // Allow subscription to register.
        await Task.yield()
        controller.insertText("x")
        let values = await task.value
        #expect(values.contains("x"))
    }
}
