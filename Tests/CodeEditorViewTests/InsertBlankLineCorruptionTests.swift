import Testing
import Foundation
@testable import CodeEditorView

@Suite("Insert blank line corruption")
@MainActor
struct InsertBlankLineCorruptionTests {
    @Test func typeOnBlankLineBetweenBlocks() {
        let src = """
        func greet() {
            return
        }

        greet()
        """
        let controller = EditorController(text: src)
        let ns = src as NSString
        // Find the blank line between } and greet
        let blank = ns.range(of: "\n\n")
        #expect(blank.location != NSNotFound)
        // Caret on blank line (second \n of the pair → after first \n of blank)
        let caret = blank.location + 1
        controller.setSelectedRange(NSRange(location: caret, length: 0))
        let linesBefore = controller.layout.lineIndex.count
        controller.insertText("x")
        print("AFTER INSERT text=\(controller.text.debugDescription)")
        print("lines before=\(linesBefore) after=\(controller.layout.lineIndex.count) docLen=\(controller.document.length) indexLen=\(controller.layout.lineIndex.length)")
        for i in 0..<controller.layout.lineIndex.count {
            if let line = controller.layout.lineIndex.line(atIndex: i) {
                let r = line.utf16Range
                let piece = (controller.text as NSString).substring(with: NSIntersectionRange(r, NSRange(location: 0, length: controller.document.length)))
                print("  line \(i) off=\(line.utf16Offset) len=\(line.metrics.utf16Length) text=\(piece.debugDescription)")
            }
        }
        #expect(controller.layout.lineIndex.length == controller.document.length)
        #expect(controller.text.contains("greet()"))
        #expect(!controller.text.contains("g\nr\ne\ne"))
        // greet should not be split into single-char lines
        let greetLines = (0..<controller.layout.lineIndex.count).compactMap { i -> String? in
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { return nil }
            let r = line.utf16Range
            guard r.length > 0, r.location + r.length <= controller.document.length else { return nil }
            return (controller.text as NSString).substring(with: r)
        }.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "g" || $0 == "g\n" }
        #expect(greetLines.count <= 1)
    }

    @Test func typeAndDeleteOnBlankLineKeepsGreetIntact() {
        let src = "func f() {\n}\n\ngreet()\n"
        let controller = EditorController(text: src)
        let caret = (src as NSString).range(of: "\n\n").location + 1
        controller.setSelectedRange(NSRange(location: caret, length: 0))
        controller.insertText("a")
        controller.deleteBackward()
        print("FINAL \(controller.text.debugDescription)")
        #expect(controller.text.contains("greet()"))
        #expect(controller.layout.lineIndex.length == controller.document.length)
    }
}
