import Foundation
import Testing

@testable import CodeEditorView

@Suite("Bash fold debug")
@MainActor
struct BashFoldDebugTests {
    @Test func collapseOuterHidesEntireBody() {
        let text = """
            greet() {
              local name="$1"
              echo "Hello, ${name}!"
              if [[ -z "${name}" ]]; then
                return 1
                extra
              fi
            }

            """
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true, showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        #expect(controller.foldStarting(atLine: 0) != nil, "greet() { must be foldable")
        #expect(controller.foldStarting(atLine: 1) == nil, "local body line is not a fold header")

        // Nested if has 2 body lines (return + extra) so it is foldable.
        let ifLine = (0..<controller.layout.lineIndex.count).first { idx in
            guard let line = controller.layout.lineIndex.line(atIndex: idx) else { return false }
            return (text as NSString).substring(with: line.utf16Range).contains("if [[")
        }
        #expect(ifLine != nil)
        if let ifLine {
            #expect(controller.foldStarting(atLine: ifLine) != nil, "if block with 2+ body lines must be foldable")
        }

        controller.toggleFold(atLine: 0)
        #expect(controller.foldModel.collapsedFolds.count == 1)

        // First body line is the bubble row (visible); remaining body hidden; `}` visible.
        if let body0 = controller.layout.lineIndex.line(atIndex: 1) {
            #expect(body0.metrics.height >= 0.5, "first body line hosts ···")
        }
        for i in 2..<controller.layout.lineIndex.count {
            guard let line = controller.layout.lineIndex.line(atIndex: i) else { continue }
            let snip = (text as NSString).substring(with: line.utf16Range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if snip.isEmpty { continue }
            if snip == "}" {
                #expect(line.metrics.height >= 0.5, "closer must stay visible")
            } else {
                #expect(
                    line.metrics.height < 0.5,
                    "body line \(i) \(snip) should be hidden"
                )
            }
        }
    }

    @Test func collapseIfOnlyHidesInnerBody() {
        let text = """
            greet() {
              local name="$1"
              if [[ -z "${name}" ]]; then
                return 1
                noop
              fi
            }

            """
        let controller = EditorController(
            text: text,
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true, showFoldingRibbon: true)
            )
        )
        controller.rebuildFolds()
        let ifLine = (0..<controller.layout.lineIndex.count).first { idx in
            guard let line = controller.layout.lineIndex.line(atIndex: idx) else { return false }
            return (text as NSString).substring(with: line.utf16Range).contains("if [[")
        }
        guard let ifLine else {
            Issue.record("if line missing")
            return
        }
        controller.toggleFold(atLine: ifLine)
        // local still visible
        if let local = controller.layout.lineIndex.line(atIndex: 1) {
            #expect(local.metrics.height >= 0.5)
        }
        // return + noop: first body of if is bubble row, second hidden
        let returnLine = (0..<controller.layout.lineIndex.count).first { idx in
            guard let line = controller.layout.lineIndex.line(atIndex: idx) else { return false }
            return (text as NSString).substring(with: line.utf16Range).contains("return")
        }
        if let returnLine, let line = controller.layout.lineIndex.line(atIndex: returnLine) {
            // First body line of the if fold — bubble row stays visible.
            #expect(line.metrics.height >= 0.5)
        }
    }
}
