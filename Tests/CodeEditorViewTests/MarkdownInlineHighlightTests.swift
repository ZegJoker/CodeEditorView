import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("Markdown inline highlight")
@MainActor
struct MarkdownInlineHighlightTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func highlightsBoldAndCode() async throws {
        let text = "hello **bold** and `code` plus https://example.com"
        let provider = try #require(TreeSitterHighlightProvider.make(for: .markdownInline))
        await provider.loadAsync(language: .markdownInline)
        await provider.setDocumentText(text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        let highlights = try await provider.queryHighlights(in: full, text: text)
        print("count=\(highlights.count)")
        for h in highlights {
            let piece = (text as NSString).substring(with: h.range)
            print("  \(h.range) raw=\(h.rawCapture ?? "") text=\(piece.debugDescription)")
        }
        #expect(!highlights.isEmpty, "expected some inline markdown captures")
    }
}
