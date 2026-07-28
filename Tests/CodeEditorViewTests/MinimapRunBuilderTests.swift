import Testing
import Foundation
@testable import CodeEditorView

@Suite("Minimap run builder")
struct MinimapRunBuilderTests {
    @Test func skipsWhitespace() {
        let bubbles = MinimapRunBuilder.bubbles(lineText: "  ab  cd\n")
        #expect(bubbles.count == 2)
        #expect(bubbles[0].column == 2)
        #expect(bubbles[0].length == 2)
        #expect(bubbles[1].column == 6)
        #expect(bubbles[1].length == 2)
    }

    @Test func emptyLine() {
        #expect(MinimapRunBuilder.bubbles(lineText: "\n").isEmpty)
        #expect(MinimapRunBuilder.bubbles(lineText: "").isEmpty)
        #expect(MinimapRunBuilder.bubbles(lineText: "   ").isEmpty)
    }

    @Test func splitsOnCaptureChange() {
        let runs: [(NSRange, CaptureName?)] = [
            (NSRange(location: 0, length: 3), .keyword),
            (NSRange(location: 3, length: 3), .string),
        ]
        let bubbles = MinimapRunBuilder.bubbles(lineText: "abcdef", captureRuns: runs)
        #expect(bubbles.count == 2)
        #expect(bubbles[0].capture == .keyword)
        #expect(bubbles[0].length == 3)
        #expect(bubbles[1].capture == .string)
    }

    @Test func minimapXUsesScale() {
        let bubble = MinimapBubbleRun(column: 4, length: 2, capture: nil)
        #expect(bubble.minimapX == MinimapMetrics.contentLeading + 4 * MinimapMetrics.charWidthScale)
        #expect(bubble.minimapWidth == 2 * MinimapMetrics.charWidthScale)
    }
}
