import Foundation
import Testing

@testable import CodeEditorView

@Suite("Line fold collapse layout")
@MainActor
struct LineFoldCollapseLayoutTests {
    @Test func collapseShrinksContentHeight() {
        let text = """
            func f() {
                let a = 1
                let b = 2
                let c = 3
            }

            """
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true, showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        let folds = controller.foldModel.foldCache.allFolds
        #expect(!folds.isEmpty, "indent provider should discover a fold")

        let heightBefore = controller.layout.lineIndex.height
        guard let fold = folds.first else { return }
        controller.foldModel.setCollapsed(true, forFold: fold)
        controller.syncFoldPlaceholdersAndHeights()

        let heightAfter = controller.layout.lineIndex.height
        #expect(heightAfter < heightBefore, "collapsed fold should reduce total height")

        var hidden = 0
        for i in 0..<controller.layout.lineIndex.count {
            if let line = controller.layout.lineIndex.line(atIndex: i), line.metrics.height < 0.5 {
                hidden += 1
            }
        }
        #expect(hidden >= 1)

        controller.foldModel.setCollapsed(false, forFold: fold)
        controller.syncFoldPlaceholdersAndHeights()
        _ = controller.layoutViewport(
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 800),
            containerWidth: 400
        )
        #expect(controller.layout.lineIndex.height >= heightAfter)
    }

    @Test func toggleFoldAtLineAPI() {
        let text = "a\n    b\n    c\nd\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        #expect(!controller.foldModel.foldCache.allFolds.isEmpty)
        // Header is line 0 ("a"); body is b+c
        controller.toggleFold(atLine: 0)
        #expect(!controller.foldModel.collapsedFolds.isEmpty)
        controller.toggleFold(atLine: 0)
        #expect(controller.foldModel.collapsedFolds.isEmpty)
    }

    @Test func placeholderSelectThenExpand() {
        let text = "func f() {\n    x\n    y\n}\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        guard let fold = controller.foldModel.foldCache.allFolds.first else {
            Issue.record("expected fold")
            return
        }
        controller.toggleFold(atLine: 0)
        #expect(!controller.foldModel.collapsedFolds.isEmpty)

        controller.handleFoldPlaceholderClick(fold)
        #expect(controller.selectedFoldPlaceholderID == fold.id)

        controller.handleFoldPlaceholderClick(fold)
        #expect(controller.foldModel.collapsedFolds.isEmpty)
        #expect(controller.selectedFoldPlaceholderID == nil)
    }

    @Test func bubbleOnFirstBodyLineNotAfterBrace() {
        let text = "func greet(_ name: String) {\n    print(1)\n    print(2)\n}\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        controller.toggleFold(atLine: 0)
        #expect(!controller.foldModel.collapsedFolds.isEmpty)

        guard let header = controller.layout.lineIndex.line(atIndex: 0),
            let body = controller.layout.lineIndex.line(atIndex: 1)
        else {
            Issue.record("lines missing")
            return
        }
        let headerText = (text as NSString).substring(with: header.utf16Range)
        #expect(headerText.contains("func greet"))
        #expect(header.metrics.height >= 0.5)
        #expect(body.metrics.height >= 0.5, "bubble row is first body line")

        let bubbleOnBody = controller.layout.attachments.items.contains { item in
            guard item.attachment is LineFoldPlaceholder else { return false }
            return item.range.location >= body.utf16Offset
                && item.range.location < body.utf16Offset + max(body.metrics.utf16Length, 1)
        }
        #expect(bubbleOnBody, "··· bubble must sit on first folded body line")
    }

    @Test func collapsedKeepsRealCloserLineEditable() {
        let text = "func greet(_ name: String) {\n    print(1)\n    print(2)\n}\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        controller.toggleFold(atLine: 0)
        #expect(!controller.foldModel.collapsedFolds.isEmpty)

        var closerVisible = false
        for i in 0..<controller.layout.lineIndex.count {
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { continue }
            let snip = (text as NSString).substring(with: line.utf16Range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if snip == "}", line.metrics.height >= 0.5 {
                closerVisible = true
            }
        }
        #expect(closerVisible, "closing brace must remain a real editable line")

        let placeholders = controller.layout.attachments.items.compactMap {
            $0.attachment as? LineFoldPlaceholder
        }
        #expect(placeholders.count == 1)
    }

    @Test func singleInnerLineIsNotFoldable() {
        let text = "func f() {\n    onlyOne()\n}\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        #expect(
            controller.foldModel.foldCache.allFolds.isEmpty,
            "one-line bodies must not be foldable"
        )
    }

    @Test func deleteSelectedFoldRemovesBody() {
        let text = "func greet(_ name: String) {\n    print(1)\n    print(2)\n}\n"
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        controller.toggleFold(atLine: 0)
        guard let fold = controller.foldModel.collapsedFolds.first else {
            Issue.record("expected collapsed fold")
            return
        }
        controller.setSelectedRange(fold.nsRange)
        controller.deleteBackward()
        #expect(controller.text.contains("func greet"))
        #expect(controller.text.contains("}"))
        #expect(!controller.text.contains("print(1)"))
        #expect(controller.foldModel.collapsedFolds.isEmpty)
    }
}
