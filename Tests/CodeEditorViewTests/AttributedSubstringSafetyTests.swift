import Foundation
import Testing

@testable import CodeEditorView

@Suite("DocumentStore substring safety")
@MainActor
struct AttributedSubstringSafetyTests {
    @Test func oobRangesNeverThrow() {
        let doc = DocumentStore(string: "hello\nworld")
        let ranges: [NSRange] = [
            NSRange(location: 0, length: 1000),
            NSRange(location: 5, length: 100),
            NSRange(location: 11, length: 1),
            NSRange(location: 12, length: 0),
            NSRange(location: 100, length: 1),
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0),
            NSRange(location: 0, length: 11),
            NSRange(location: 0, length: 12),
        ]
        for r in ranges {
            let s = doc.attributedSubstring(from: r)
            #expect(s.length >= 0)
            #expect(s.length <= doc.length)
        }
    }

    @Test func typesetWithFoldMinimapAnnotationsDoesNotCrash() {
        let controller = EditorController(
            text: "func a() {\n  return\n}\n",
            configuration: .init(
                showGutter: true,
                showMinimap: true,
                showFoldingRibbon: true
            ),
            language: .swift
        )
        controller.installFoldingIfNeeded()
        controller.rebuildFolds()
        controller.setAnnotations([
            LineAnnotation(line: 1, severity: .error, message: "e", range: NSRange(location: 12, length: 6))
        ])
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            containerWidth: 800
        )
        for _ in 0..<50 {
            controller.insertText("x")
            _ = controller.layoutViewport(
                visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                containerWidth: 800
            )
        }
        controller.deleteBackward()
        controller.insertNewline()
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            containerWidth: 800
        )
        #expect(controller.document.length > 0)
    }
}
