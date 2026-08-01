import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Demo sample edit")
@MainActor
struct DemoSampleEditTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func swiftSampleTypeOnBlankLineBeforeGreet() {
        let src = """
            // Swift — CodeEditorView demo
            func greet(_ name: String) {
                print("Hello, \\(name)!")
                if name.isEmpty {
                    return
                }
            }

            greet("world")
            """
        let controller = EditorController(text: src, language: .swift)
        let caret = (src as NSString).range(of: "}\n\n").location + 2
        controller.setSelectedRange(NSRange(location: caret, length: 0))
        let lineCountBefore = controller.layout.lineIndex.count
        let lenBefore = controller.layout.lineIndex.length
        controller.insertText("z")
        print("docLen=\(controller.document.length) indexLen=\(controller.layout.lineIndex.length)")
        print("text=\(controller.text.debugDescription)")
        for i in 0..<controller.layout.lineIndex.count {
            if let line = controller.layout.lineIndex.line(atIndex: i) {
                let r = line.utf16Range
                let piece: String
                if r.location + r.length <= controller.document.length, r.length >= 0 {
                    piece = (controller.text as NSString).substring(with: r)
                } else {
                    piece = "<OOB \(r)>"
                }
                print("  \(i): off=\(line.utf16Offset) len=\(line.metrics.utf16Length) \(piece.debugDescription)")
            }
        }
        #expect(controller.layout.lineIndex.length == controller.document.length)
        #expect(controller.text.contains("greet(\"world\")") || controller.text.contains("greet"))
        // Last non-empty content line should still contain greet call (or z line + greet line)
        let joined = (0..<controller.layout.lineIndex.count).compactMap { i -> String? in
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { return nil }
            let r = line.utf16Range
            guard r.location + r.length <= controller.document.length else { return nil }
            return (controller.text as NSString).substring(with: r)
        }.joined()
        #expect(joined == controller.text, "line index must cover full document text")
        #expect(
            controller.layout.lineIndex.count == lineCountBefore
                || controller.layout.lineIndex.count == lineCountBefore + 0)
    }
}
