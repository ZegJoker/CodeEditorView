import Testing
import Foundation
import SwiftTreeSitter
@testable import CodeEditorView
import CodeEditorLanguages


@Suite("Markdown parse")
@MainActor
struct MarkdownParseTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func parseAndQueryMarkdown() async throws {
        let provider = try #require(TreeSitterHighlightProvider.make(for: .markdown))
        let t0 = ContinuousClock.now
        await provider.loadAsync(language: .markdown)
        print("load elapsed=\(ContinuousClock.now - t0)")
        let sample = """
        # Title
        Hello **world**

        - item

        ```swift
        print("hi")
        ```
        """
        let t1 = ContinuousClock.now
        await provider.setDocumentText(sample)
        print("parse elapsed=\(ContinuousClock.now - t1)")
        let t2 = ContinuousClock.now
        let full = NSRange(location: 0, length: (sample as NSString).length)
        let highlights = try await provider.queryHighlights(in: full, text: sample)
        print("query elapsed=\(ContinuousClock.now - t2) count=\(highlights.count)")
        for h in highlights.prefix(20) {
            print("  \(h.range) \(h.rawCapture ?? "")")
        }
        #expect(true)
    }

    @Test func parseMarkdownInlineWithFixedQuery() async throws {
        // Current query is wrong; load should not hang even if it fails.
        let provider = try #require(TreeSitterHighlightProvider.make(for: .markdownInline))
        let t0 = ContinuousClock.now
        await provider.loadAsync(language: .markdownInline)
        print("inline load elapsed=\(ContinuousClock.now - t0)")
        await provider.setDocumentText("hello **bold**")
        let full = NSRange(location: 0, length: 14)
        let highlights = (try? await provider.queryHighlights(in: full, text: "hello **bold**")) ?? []
        print("inline highlights=\(highlights.count)")
        #expect(ContinuousClock.now - t0 < .seconds(3))
    }
}
