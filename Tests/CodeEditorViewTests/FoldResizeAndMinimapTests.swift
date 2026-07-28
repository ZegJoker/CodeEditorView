import Testing
import Foundation
import CoreGraphics
@testable import CodeEditorView

@Suite("Fold resize and minimap")
@MainActor
struct FoldResizeAndMinimapTests {
    @Test func invalidateAllPreservesCollapsedHeights() {
        let text = """
        func greet(_ name: String) {
            if name.isEmpty {
                return
                pass
            }
            print(name)
            print(name)
        }

        """
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true, showMinimap: true, showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        controller.toggleFold(atLine: 0)
        #expect(!controller.foldModel.collapsedFolds.isEmpty)

        controller.layout.invalidateAll()
        // Force the viewport path that runs after window resize.
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 800),
            containerWidth: 400
        )

        // No ghost body lines with positive height after rebuild.
        var ghost = 0
        for i in 0..<controller.layout.lineIndex.count {
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { continue }
            let hidden = controller.layout.isLineHiddenByCollapsedFold(line.utf16Range)
            if hidden, line.metrics.height >= 0.5 {
                ghost += 1
            }
        }
        #expect(ghost == 0, "hidden fold body/closer lines must stay height 0 after invalidateAll")
    }

    @Test func minimapSkipsCollapsedBodyLines() {
        let text = """
        func greet(_ name: String) {
            if name.isEmpty {
                return
                pass
            }
            print(name)
            print(name)
        }
        greet("world")

        """
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true, showMinimap: true, showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        let before = controller.minimapSnapshot(
            visibleMinimapRect: CGRect(x: 0, y: 0, width: 100, height: 10_000)
        )
        controller.toggleFold(atLine: 0)
        let after = controller.minimapSnapshot(
            visibleMinimapRect: CGRect(x: 0, y: 0, width: 100, height: 10_000)
        )
        #expect(after.lines.count < before.lines.count, "minimap must drop folded body rows")
        // Nested `return` / second body lines are fully hidden from minimap rows.
        let painted = after.lines.compactMap { paint -> String? in
            controller.layout.lineIndex.line(atIndex: paint.lineIndex).map { line in
                (controller.document.substring(from: line.utf16Range) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        #expect(!painted.contains(where: { $0.contains("return") }))
        #expect(!painted.contains(where: { $0.contains("print(name)") }))
        #expect(painted.contains(where: { $0.contains("func greet") }))
    }
}
