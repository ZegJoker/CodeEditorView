import Testing
import Foundation
@testable import CodeEditorView

@Suite("Blank line delete exact")
@MainActor
struct BlankLineDeleteExactTests {
    func dump(_ controller: EditorController, label: String) {
        print("== \(label) ==")
        print("text=\(controller.text.debugDescription)")
        print("caret=\(controller.selectedRange) docLen=\(controller.document.length) indexLen=\(controller.layout.lineIndex.length) lines=\(controller.layout.lineIndex.count)")
        for i in 0..<controller.layout.lineIndex.count {
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { continue }
            let r = line.utf16Range
            let piece: String
            if r.length == 0 {
                piece = "<empty>"
            } else if r.location + r.length <= controller.document.length {
                piece = (controller.text as NSString).substring(with: r)
            } else {
                piece = "<OOB>"
            }
            print("  L\(i) off=\(line.utf16Offset) len=\(line.metrics.utf16Length) \(piece.debugDescription)")
        }
    }

    @Test func welcomeScenario() {
        let controller = EditorController(text: "")
        controller.insertText("func welcome(name: String) ")
        controller.insertText("{")
        controller.insertNewline()
        dump(controller, label: "after enter")
        // CESE DeleteWhitespaceFilter: one Delete removes the whole indent unit.
        controller.deleteBackward()
        dump(controller, label: "after indent unit gone")
        #expect(controller.text == "func welcome(name: String) {\n\n}")
        // Column 0 of blank — CESE deletes previous `\n`, caret stays after `{`.
        controller.deleteBackward()
        dump(controller, label: "after blank delete")
        #expect(controller.text == "func welcome(name: String) {\n}")
        #expect(controller.layout.lineIndex.count == 2, "should be open line + closer only, got \(controller.layout.lineIndex.count)")
        let afterOpen = (controller.text as NSString).range(of: "{").location + 1
        #expect(controller.selectedRange.location == afterOpen,
                "caret must stay after '{{' (CESE), not jump to col 0 of closer")
        // No phantom empty between
        if let l0 = controller.layout.lineIndex.line(atIndex: 0),
           let l1 = controller.layout.lineIndex.line(atIndex: 1) {
            #expect(l0.metrics.utf16Length > 0)
            #expect(l1.metrics.utf16Length > 0, "no zero-length phantom before closer")
            #expect(l1.utf16Offset == l0.utf16Offset + l0.metrics.utf16Length)
            let closer = (controller.text as NSString).substring(with: l1.utf16Range)
            #expect(closer.hasPrefix("}"))
        }
        // Column 0 of closer joins to `{}`
        controller.setSelectedRange(NSRange(location: (controller.text as NSString).range(of: "}").location, length: 0))
        controller.deleteBackward()
        #expect(controller.text == "func welcome(name: String) {}")
    }
}
