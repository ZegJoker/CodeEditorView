import Foundation
import Testing

@testable import CodeEditorView

@Suite("Find engine")
struct FindEngineTests {
    @Test func containsMatchesCESEFixture() {
        let doc = "test1\ntest2\ntest3"
        let matches = FindEngine.matches(in: doc, query: "test", method: .contains, matchCase: false)
        #expect(matches.count == 3)
        #expect(matches[0].location == 0)
        #expect(matches[1].location == 6)
        #expect(matches[2].location == 12)
    }

    @Test func emptyQueryReturnsNoMatches() {
        let matches = FindEngine.matches(in: "abc", query: "", method: .contains, matchCase: false)
        #expect(matches.isEmpty)
    }

    @Test func matchCaseToggle() {
        let doc = "Test1\ntest2\nTEST3"
        let sensitive = FindEngine.matches(in: doc, query: "Test", method: .contains, matchCase: true)
        #expect(sensitive.count == 1)
        let insensitive = FindEngine.matches(in: doc, query: "Test", method: .contains, matchCase: false)
        #expect(insensitive.count == 3)
    }

    @Test func matchesWord() {
        let doc = "test1 test2 test3"
        let whole = FindEngine.matches(in: doc, query: "test1", method: .matchesWord, matchCase: false)
        #expect(whole.count == 1)
        let partial = FindEngine.matches(in: doc, query: "test", method: .matchesWord, matchCase: false)
        #expect(partial.isEmpty)
    }

    @Test func startsWithAndEndsWith() {
        let doc = "test1 test2 test3\nprefix_test test_suffix\nword_test_word"
        let starts = FindEngine.matches(in: doc, query: "prefix", method: .startsWith, matchCase: false)
        #expect(starts.count == 1)
        let ends = FindEngine.matches(in: doc, query: "suffix", method: .endsWith, matchCase: false)
        #expect(ends.count == 1)
    }

    @Test func regularExpression() {
        let doc = "test1 test2 test3"
        let matches = FindEngine.matches(in: doc, query: "test\\d", method: .regularExpression, matchCase: false)
        #expect(matches.count == 3)
    }

    @Test func invalidRegexReturnsEmpty() {
        let matches = FindEngine.matches(in: "abc", query: "[", method: .regularExpression, matchCase: false)
        #expect(matches.isEmpty)
    }

    @Test func nearestMatchIndex() {
        let matches = [
            NSRange(location: 0, length: 4),
            NSRange(location: 10, length: 4),
            NSRange(location: 20, length: 4),
        ]
        #expect(FindEngine.nearestMatchIndex(matches: matches, toCaret: 0) == 0)
        #expect(FindEngine.nearestMatchIndex(matches: matches, toCaret: 11) == 1)
        #expect(FindEngine.nearestMatchIndex(matches: matches, toCaret: 25) == 2)
        #expect(FindEngine.nearestMatchIndex(matches: [], toCaret: 0) == nil)
    }

    @Test func containsComplexTextCount() {
        let doc = "test1 test2 test3\nprefix_test test_suffix\nword_test_word"
        let matches = FindEngine.matches(in: doc, query: "test", method: .contains, matchCase: false)
        #expect(matches.count == 6)
    }
}
