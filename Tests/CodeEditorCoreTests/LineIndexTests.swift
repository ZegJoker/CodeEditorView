import Testing
import Foundation
@testable import CodeEditorCore

@MainActor
final class TestLine: LinePayload {
    let id = UUID()
}

@Suite("LineIndex")
struct LineIndexTests {
    @Test func emptyIndex() {
        let index = LineIndex<TestLine>()
        #expect(index.count == 0)
        #expect(index.length == 0)
        #expect(index.first == nil)
    }

    @Test func buildFromSimpleString() {
        let index = LineIndex<TestLine>.build(
            from: "a\nb\nc",
            estimatedLineHeight: 10
        ) { _ in TestLine() }

        #expect(index.count == 3)
        #expect(index.line(atIndex: 0)?.metrics.utf16Length == 2) // "a\n"
        #expect(index.line(atIndex: 1)?.metrics.utf16Length == 2) // "b\n"
        #expect(index.line(atIndex: 2)?.metrics.utf16Length == 1) // "c"
        #expect(index.length == 5)
    }

    @Test func buildTrailingNewlineAddsEmptyLine() {
        let index = LineIndex<TestLine>.build(
            from: "a\n",
            estimatedLineHeight: 10
        ) { _ in TestLine() }

        #expect(index.count == 2)
        #expect(index.line(atIndex: 1)?.metrics.utf16Length == 0)
    }

    @Test func lookupByOffsetAndY() {
        let index = LineIndex<TestLine>()
        index.rebuild(lines: [
            (TestLine(), LineMetrics(utf16Length: 3, height: 10)),
            (TestLine(), LineMetrics(utf16Length: 4, height: 20)),
            (TestLine(), LineMetrics(utf16Length: 2, height: 10)),
        ])

        #expect(index.line(atUTF16Offset: 0)?.index == 0)
        #expect(index.line(atUTF16Offset: 3)?.index == 1)
        #expect(index.line(atUTF16Offset: 8)?.index == 2)
        #expect(index.line(atY: 5)?.index == 0)
        #expect(index.line(atY: 15)?.index == 1)
        #expect(index.line(atY: 35)?.index == 2)
        #expect(index.height == 40)
    }

    @Test func insertAndRemove() {
        let index = LineIndex<TestLine>()
        index.rebuild(lines: [
            (TestLine(), LineMetrics(utf16Length: 2, height: 10)),
            (TestLine(), LineMetrics(utf16Length: 2, height: 10)),
        ])

        index.insert(payload: TestLine(), metrics: LineMetrics(utf16Length: 5, height: 12), atIndex: 1)
        #expect(index.count == 3)
        #expect(index.line(atIndex: 1)?.metrics.utf16Length == 5)
        #expect(index.length == 9)
        #expect(index.height == 32)

        index.remove(atIndex: 1)
        #expect(index.count == 2)
        #expect(index.length == 4)
        #expect(index.height == 20)
    }

    @Test func largeBuild() {
        let lineCount = 5_000
        let text = (0..<lineCount).map { "line \($0)" }.joined(separator: "\n")
        let index = LineIndex<TestLine>.build(from: text, estimatedLineHeight: 14) { _ in TestLine() }
        #expect(index.count == lineCount)
        #expect(index.line(atIndex: lineCount - 1) != nil)
        #expect(index.line(atUTF16Offset: index.length - 1) != nil)
    }
}
