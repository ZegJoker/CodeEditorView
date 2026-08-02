import Foundation
import SwiftTreeSitter
import Testing

@testable import CodeEditorLanguages

@Suite("TS and Markdown load")
struct TSMarkdownLoadTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func typescriptPatternCountIncludesParent() throws {
        let ts = try CodeLanguages.languageConfiguration(for: .typescript)
        let count = ts?.queries[.highlights]?.patternCount ?? 0
        print("TS pattern count=\(count)")
        #expect(count >= 30, "TS + JS parent should produce a rich highlight query")
    }

    @Test func typescriptLoadsWithJSParent() throws {
        let ts = try CodeLanguages.languageConfiguration(for: .typescript)
        let count = ts?.queries[.highlights]?.patternCount ?? 0
        print("TS+parent pattern count=\(count)")
        #expect(count > 20, "TS should inherit JS highlights via parent")
    }

    @Test func markdownInlineQueryCompiles() throws {
        let config = try CodeLanguages.languageConfiguration(for: .markdownInline)
        let count = config?.queries[.highlights]?.patternCount ?? 0
        print("MarkdownInline patterns=\(count)")
        #expect(config != nil)
        #expect(count > 0)
    }

    @Test func markdownConfigLoadTime() throws {
        let t0 = ContinuousClock.now
        let config = try CodeLanguages.languageConfiguration(for: .markdown)
        print(
            "Markdown config elapsed=\(ContinuousClock.now - t0) patterns=\(config?.queries[.highlights]?.patternCount ?? -1)"
        )
        #expect(config != nil)
    }

    @Test func markdownInlineConfigLoadTime() throws {
        let t0 = ContinuousClock.now
        let config = try CodeLanguages.languageConfiguration(for: .markdownInline)
        print(
            "MarkdownInline config elapsed=\(ContinuousClock.now - t0) patterns=\(config?.queries[.highlights]?.patternCount ?? -1)"
        )
        #expect(config != nil)
    }

    @Test func jsConfigPatternCount() throws {
        let js = try CodeLanguages.languageConfiguration(for: .javascript)
        let count = js?.queries[.highlights]?.patternCount ?? 0
        print("JS pattern count=\(count)")
        #expect(count > 20)
    }
}
