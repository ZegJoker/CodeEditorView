import Testing
import Foundation
@testable import CodeEditorView

@Suite("Gutter and configuration")
@MainActor
struct GutterAndConfigTests {
    @Test func gutterWidthGrowsWithLineCount() {
        let small = GutterModel(lineCount: 9, font: PlatformDefaults.monospacedFont)
        let large = GutterModel(lineCount: 1000, font: PlatformDefaults.monospacedFont)
        #expect(large.width > small.width)
        #expect(small.digitCount == 2)
        #expect(large.digitCount == 4)
    }

    @Test func nestedConfigurationFlatAccessors() {
        var config = EditorConfiguration(
            appearance: .init(wrapLines: false, tabWidth: 2),
            behavior: .init(indentOption: .tab, reformatAtColumn: 100),
            peripherals: .init(showGutter: true, showReformattingGuide: true)
        )
        #expect(config.wrapLines == false)
        #expect(config.behavior.reformatAtColumn == 100)
        config.wrapLines = true
        #expect(config.appearance.wrapLines == true)
        #expect(config.peripherals.showGutter == true)
    }

    @Test func controllerAppliesGutterInset() {
        let controller = EditorController(
            text: "a\nb\nc",
            configuration: EditorConfiguration(
                peripherals: .init(showGutter: true)
            )
        )
        #expect(controller.gutterWidth > 0)
        #expect(controller.layout.edgeInsets.leading >= controller.gutterWidth)

        controller.configuration.peripherals.showGutter = false
        #expect(controller.gutterWidth == 0)
    }

    @Test func bracketEmphasisOnSelection() {
        let controller = EditorController(
            text: "x = (1 + 2)",
            configuration: EditorConfiguration(
                appearance: .init(bracketPairEmphasis: .bordered)
            )
        )
        let open = (controller.text as NSString).range(of: "(").location
        controller.setSelectedRange(NSRange(location: open + 1, length: 0))
        let bracketItems = controller.emphasis.items.filter { $0.group == "bracket-pairs" }
        #expect(bracketItems.count == 2)
    }

    @Test func cursorPositionsTrackLines() {
        let controller = EditorController(text: "one\ntwo\nthree")
        // Offset of 't' in two
        controller.setSelectedRange(NSRange(location: 4, length: 0))
        let cursors = controller.cursorPositions
        #expect(cursors.count == 1)
        #expect(cursors[0].line == 1)
        #expect(cursors[0].column == 0)
    }

    @Test func themeMapsCaptures() {
        let theme = EditorTheme.default
        #expect(theme.attribute(for: .keyword).bold == true)
        #expect(theme.attribute(for: .comment).italic == true)
        #expect(theme.color(for: .string) == theme.strings.color)
    }

    @Test func coordinatorReceivesCallbacks() async {
        final class Probe: EditorCoordinator {
            var prepared = false
            var textChanges = 0
            var selectionChanges = 0

            func prepare(controller: EditorController) {
                prepared = true
            }

            func textDidChange(controller: EditorController) {
                textChanges += 1
            }

            func selectionDidChange(controller: EditorController, cursors: [CursorPosition]) {
                selectionChanges += 1
            }
        }

        let probe = Probe()
        let controller = EditorController(text: "hi", coordinators: [probe])
        #expect(probe.prepared == true)
        controller.insertText("!")
        #expect(probe.textChanges >= 1)
        controller.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(probe.selectionChanges >= 1)
    }
}
