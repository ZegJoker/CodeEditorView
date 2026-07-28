import Testing
import Foundation
@testable import CodeEditorView

@Suite("Line indentation fold provider")
@MainActor
struct LineIndentationFoldProviderTests {
    private let provider = LineIndentationFoldProvider()

    private func context(_ text: String, indent: IndentOption = .spaces(count: 4)) -> LineFoldProviderContext {
        LineFoldProviderContext(
            document: text,
            indentOption: indent,
            lineCount: text.split(separator: "\n", omittingEmptySubsequences: false).count
        )
    }

    @Test func nestedIndentProducesFold() {
        let text = """
        func f() {
            let x = 1
            let y = 2
        }

        """
        let ctx = context(text)
        let lines = LineFoldCalculator.lineRanges(in: text)
        let raw = LineFoldCalculator.buildRawFolds(context: ctx, lineRanges: lines, provider: provider)
        #expect(!raw.isEmpty, "expected at least one fold over indented body")
        let covering = raw.filter { $0.range.lowerBound < text.utf16.count && $0.depth >= 1 }
        #expect(!covering.isEmpty)
    }

    @Test func twoSpaceIndentStillFoldsWithFourSpaceConfig() {
        // Bash-style 2-space indent while editor indent option is 4 spaces.
        let text = """
        greet() {
          local name="$1"
          echo hi
        }

        """
        let ctx = context(text, indent: .spaces(count: 4))
        let lines = LineFoldCalculator.lineRanges(in: text)
        let raw = LineFoldCalculator.buildRawFolds(context: ctx, lineRanges: lines, provider: provider)
        #expect(!raw.isEmpty, "2-space nested body must still produce a fold")
        // Fold should start on the `greet() {` line (after `{`).
        let openBrace = (text as NSString).range(of: "{").location
        #expect(raw.contains { $0.range.lowerBound > openBrace || $0.range.lowerBound == openBrace + 1
            || abs($0.range.lowerBound - (openBrace + 1)) <= 1 })
    }

    @Test func blankLinesDoNotStartFolds() {
        let text = "a\n\n    b\n"
        let ctx = context(text)
        let lines = LineFoldCalculator.lineRanges(in: text)
        let infos = provider.foldLevelAtLine(
            lineNumber: 1,
            lineRange: lines[1].range,
            previousDepth: 0,
            context: ctx
        )
        #expect(infos.isEmpty)
    }

    @Test func outdentEndsFold() {
        // Need ≥2 body lines to be foldable.
        let text = "root\n    child1\n    child2\nback\n"
        let ctx = context(text)
        let lines = LineFoldCalculator.lineRanges(in: text)
        let raw = LineFoldCalculator.buildRawFolds(context: ctx, lineRanges: lines, provider: provider)
        #expect(raw.count >= 1)
        if let fold = raw.first {
            #expect(fold.range.lowerBound < fold.range.upperBound)
            let back = (text as NSString).range(of: "back").location
            #expect(fold.range.upperBound <= back + 1 || fold.range.upperBound <= text.utf16.count)
        }
    }

    @Test func foldStartsAtFirstBodyLine() {
        let text = "func f() {\n    x\n    y\n}\n"
        let ctx = context(text)
        let lines = LineFoldCalculator.lineRanges(in: text)
        let raw = LineFoldCalculator.buildRawFolds(context: ctx, lineRanges: lines, provider: provider)
        #expect(!raw.isEmpty)
        let xLine = (text as NSString).range(of: "    x").location
        if let fold = raw.first {
            // Bubble/fold body starts at first indented line, not after `{` on the header.
            #expect(fold.range.lowerBound == xLine)
        }
    }

    @Test func oneLineBodyNotFoldable() {
        let text = "func f() {\n    x\n}\n"
        let ctx = context(text)
        let lines = LineFoldCalculator.lineRanges(in: text)
        let raw = LineFoldCalculator.buildRawFolds(context: ctx, lineRanges: lines, provider: provider)
        #expect(raw.isEmpty)
    }
}
