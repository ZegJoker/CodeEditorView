import Foundation
import Testing

@testable import CodeEditorView

@Suite("Line annotation store")
@MainActor
struct LineAnnotationStoreTests {
    @Test func setAndGroupByLine() {
        let store = LineAnnotationStore()
        store.setAnnotations([
            LineAnnotation(line: 1, severity: .error, message: "e1"),
            LineAnnotation(line: 1, column: 4, severity: .warning, message: "w1"),
            LineAnnotation(line: 3, severity: .info, message: "i1"),
        ])
        #expect(store.items.count == 3)
        #expect(store.annotations(onLine: 1).count == 2)
        #expect(store.annotations(onLine: 3).count == 1)
        #expect(store.annotations(onLine: 0).isEmpty)
        // Chips are trailing overlays — no extra band height.
        #expect(store.bandHeight(forLine: 1) == 0)
        #expect(store.bandHeight(forLine: 0) == 0)
    }

    @Test func clear() {
        let store = LineAnnotationStore()
        store.setAnnotations([LineAnnotation(line: 0, severity: .error, message: "x")])
        store.clear()
        #expect(store.items.isEmpty)
        #expect(store.byLine.isEmpty)
    }

    @Test func shiftRangesOnEdit() {
        let store = LineAnnotationStore()
        store.setAnnotations([
            LineAnnotation(
                line: 0,
                severity: .error,
                message: "after",
                range: NSRange(location: 10, length: 3)
            ),
            LineAnnotation(
                line: 0,
                severity: .warning,
                message: "before",
                range: NSRange(location: 1, length: 2)
            ),
            LineAnnotation(
                line: 0,
                severity: .info,
                message: "overlap",
                range: NSRange(location: 4, length: 4)
            ),
        ])
        // Insert 5 chars at location 5 (length 0 insert).
        store.documentDidEdit(editedRange: NSRange(location: 5, length: 0), delta: 5)
        let ranges = store.items.compactMap(\.range).sorted { $0.location < $1.location }
        #expect(ranges.contains { $0.location == 1 && $0.length == 2 })  // before unchanged
        #expect(ranges.contains { $0.location == 15 && $0.length == 3 })  // after shifted
        #expect(!store.items.contains { $0.message == "overlap" })  // overlapped dropped
    }

    @Test func clampLines() {
        let store = LineAnnotationStore()
        store.setAnnotations([
            LineAnnotation(line: 0, severity: .error, message: "ok"),
            LineAnnotation(line: 9, severity: .error, message: "gone"),
        ])
        store.clampLines(lineCount: 3)
        #expect(store.items.count == 1)
        #expect(store.items.first?.message == "ok")
    }
}

@Suite("Line annotation layout")
@MainActor
struct LineAnnotationLayoutTests {
    @Test func setAnnotationsDoesNotChangeLineHeight() {
        // mchakravarty style: chips trail on the line; no under-line band height.
        let text = "func f() {\n    a\n    b\n}\n"
        let controller = EditorController(text: text)
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 600),
            containerWidth: 400
        )
        let heightBefore = controller.layout.lineIndex.height
        controller.setAnnotations([
            LineAnnotation(line: 1, severity: .error, message: "bad"),
            LineAnnotation(line: 1, severity: .warning, message: "also"),
        ])
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 600),
            containerWidth: 400
        )
        #expect(controller.annotations.count == 2)
        #expect(abs(controller.layout.lineIndex.height - heightBefore) < 1)
        controller.clearAnnotations()
        #expect(controller.annotations.isEmpty)
    }

    @Test func underlineEmphasisForRangedAnnotations() {
        let text = "let value = 1\n"
        let controller = EditorController(text: text)
        controller.setAnnotations([
            LineAnnotation(
                line: 0,
                column: 4,
                severity: .error,
                message: "unused",
                range: NSRange(location: 4, length: 5)
            )
        ])
        let diags = controller.emphasis.items.filter { $0.group == EmphasisGroup.diagnostics }
        #expect(diags.count == 1)
        #expect(diags.first?.range.location == 4)
        controller.clearAnnotations()
        #expect(controller.emphasis.items.filter { $0.group == EmphasisGroup.diagnostics }.isEmpty)
    }
}
