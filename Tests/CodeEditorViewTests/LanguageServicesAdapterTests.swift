import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageSupport
import CodeEditorLanguageServices
@testable import CodeEditorView

@Suite("Language service adapters")
@MainActor
struct LanguageServicesAdapterTests {
    @Test func diagnosticsMapperMapsSeverityAndRange() {
        let text = "let x = 1\n"
        let diagnostics = [
            LanguageDiagnostic(
                range: CodeEditorCore.TextRange(location: 4, length: 1),
                severity: .error,
                message: "bad",
                code: "E1",
                source: "mock"
            ),
            LanguageDiagnostic(
                range: CodeEditorCore.TextRange(location: 0, length: 3),
                severity: .hint,
                message: "hint"
            ),
        ]
        let annotations = DiagnosticsAnnotationMapper.annotations(
            from: diagnostics,
            documentText: text
        )
        #expect(annotations.count == 2)
        #expect(annotations[0].severity == .error)
        #expect(annotations[0].message == "bad")
        #expect(annotations[0].detail == "mock · E1")
        #expect(annotations[0].range == NSRange(location: 4, length: 1))
        #expect(annotations[1].severity == .live)
    }

    @Test func completionItemWrapsTextEditPlan() {
        let plan = TextEditPlan(range: CodeEditorCore.TextRange(location: 0, length: 3), newText: "hello()")
        let item = CompletionItem(
            label: "hello",
            kind: .function,
            insertText: "hello()",
            textEdit: plan
        )
        let entry = LanguageCompletionItem(item: item)
        #expect(entry.label == "hello")
        #expect(entry.textEdit?.newText == "hello()")
        #expect(entry.insertText == "hello()")
        #expect(entry.systemImage == "function")
    }

    @Test func definitionLinkMapping() {
        let uri = DocumentURI(rawValue: "inmemory:doc")
        let link = LocationLink(
            targetURI: uri,
            targetRange: CodeEditorCore.TextRange(location: 5, length: 2),
            targetSelectionRange: CodeEditorCore.TextRange(location: 5, length: 2)
        )
        let jump = DefinitionProviderJumpAdapter.makeJumpLink(
            from: link,
            fallbackDocument: "hello world"
        )
        #expect(jump.url == nil)
        #expect(jump.targetRange.range.location == 5)
        #expect(jump.targetRange.line == 0)
    }

    @Test func semanticTokensHighlightAdapterQueries() async throws {
        let registry = LanguageServiceRegistry()
        let tokens = [
            SemanticTokenSpan(
                range: CodeEditorCore.TextRange(location: 0, length: 3),
                capture: .keyword,
                rawType: "keyword"
            ),
        ]
        let mock = MockLanguageSuite(id: "sem", semanticTokens: tokens)
        await registry.register(mock as any SemanticTokensProvider)
        let host = LanguageServiceHost(registry: registry)
        let adapter = SemanticTokensHighlightAdapter(host: host)
        adapter.setTokens(tokens)
        let highlights = try await adapter.queryHighlights(
            in: NSRange(location: 0, length: 10),
            text: "let x = 1"
        )
        #expect(highlights.count == 1)
        #expect(highlights[0].capture == .keyword)
    }

    @Test func foldingAdapterEmitsStartAndEnd() {
        let adapter = FoldingRangeProviderAdapter(ranges: [
            FoldingRange(startLine: 0, endLine: 2, startCharacter: 0, endCharacter: 1),
        ])
        let ctx = LineFoldProviderContext(document: "a\nb\nc\n", indentOption: .spaces(count: 4), lineCount: 3)
        let start = adapter.foldLevelAtLine(
            lineNumber: 0,
            lineRange: NSRange(location: 0, length: 2),
            previousDepth: 0,
            context: ctx
        )
        let end = adapter.foldLevelAtLine(
            lineNumber: 2,
            lineRange: NSRange(location: 4, length: 2),
            previousDepth: 1,
            context: ctx
        )
        #expect(!start.isEmpty)
        #expect(!end.isEmpty)
        if case .startFold = start[0] {
            // ok
        } else {
            Issue.record("expected startFold")
        }
        if case .endFold = end[0] {
            // ok
        } else {
            Issue.record("expected endFold")
        }
    }

    @Test func completionAdapterLoadsFromHost() async throws {
        let registry = LanguageServiceRegistry()
        let mock = MockLanguageSuite.sample()
        await registry.register(mock as any CompletionProvider)
        let host = LanguageServiceHost(registry: registry)
        let adapter = CompletionProviderDelegateAdapter(host: host)
        let controller = EditorController(text: "hel")
        let cursor = CursorPosition(range: NSRange(location: 3, length: 0), line: 0, column: 3)
        let result = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor
        )
        #expect(result != nil)
        #expect(!(result?.items.isEmpty ?? true))
        #expect(result?.items.first is LanguageCompletionItem)
    }
}
