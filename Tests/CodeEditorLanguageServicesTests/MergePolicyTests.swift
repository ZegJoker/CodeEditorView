import CodeEditorCore
import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorLanguageServices

@Suite("Merge policies")
struct MergePolicyTests {
    @Test func completionMergesAndDedupes() {
        let a = CompletionList(items: [
            CompletionItem(label: "foo", insertText: "foo", sortText: "1"),
            CompletionItem(label: "bar", insertText: "bar", sortText: "2"),
        ])
        let b = CompletionList(items: [
            CompletionItem(label: "foo", insertText: "foo", sortText: "0"),  // duplicate
            CompletionItem(label: "baz", insertText: "baz", sortText: "0"),
        ])
        let merged = LanguageServiceMerge.completions(from: [
            (priority: 10, list: a),
            (priority: 5, list: b),
        ])
        #expect(
            merged.items.map(\.label) == ["bar", "foo", "baz"]
                || Set(merged.items.map(\.label)) == Set(["foo", "bar", "baz"]))
        #expect(merged.items.filter { $0.label == "foo" }.count == 1)
        #expect(merged.items.count == 3)
    }

    @Test func diagnosticsSortByRangeThenSeverity() {
        let d1 = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: 10, length: 1),
            severity: .warning,
            message: "w"
        )
        let d2 = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: 5, length: 1),
            severity: .error,
            message: "e"
        )
        let d3 = LanguageDiagnostic(
            range: CodeEditorCore.TextRange(location: 5, length: 1),
            severity: .hint,
            message: "h"
        )
        let merged = LanguageServiceMerge.diagnostics([[d1], [d2, d3]])
        #expect(merged.map(\.message) == ["e", "h", "w"])
    }

    @Test func hoverSectionsCap() {
        let h1 = Hover(sections: [
            HoverSection(content: .plain("a")),
            HoverSection(content: .plain("b")),
        ])
        let h2 = Hover(sections: [
            HoverSection(content: .plain("c"))
        ])
        let merged = LanguageServiceMerge.hoverSections([h1, h2], max: 2)
        #expect(merged?.sections.count == 2)
        #expect(merged?.sections.map(\.content.value) == ["a", "b"])
    }

    @Test func foldingTakesFirstNonEmpty() {
        let empty: [FoldingRange] = []
        let ranges = [FoldingRange(startLine: 0, endLine: 2)]
        #expect(LanguageServiceMerge.foldingRanges([empty, ranges]).count == 1)
        #expect(LanguageServiceMerge.foldingRanges([empty, empty]).isEmpty)
    }

    @Test func locationLinksDedupe() {
        let uri = DocumentURI(rawValue: "inmemory:x")
        let r = CodeEditorCore.TextRange(location: 0, length: 1)
        let link = LocationLink(targetURI: uri, targetRange: r)
        let merged = LanguageServiceMerge.locationLinks([[link], [link]])
        #expect(merged.count == 1)
    }
}
