import Foundation
import Testing

@testable import CodeEditorCore

@Suite("BracketMatcher")
struct BracketMatcherTests {
    @Test func matchesOpeningParen() {
        let text = "func f() {}"
        // Caret after '('
        let openIndex = (text as NSString).range(of: "(").location
        let match = BracketMatcher.match(aroundUTF16Offset: openIndex + 1, in: text)
        #expect(match != nil)
        #expect(match?.open.location == openIndex)
        #expect(match?.close.location == openIndex + 1)
    }

    @Test func matchesNestedBraces() {
        let text = "{ a { b } c }"
        // Caret after first '{'
        let match = BracketMatcher.match(aroundUTF16Offset: 1, in: text)
        #expect(match != nil)
        #expect(match?.open.location == 0)
        #expect(match?.close.location == (text as NSString).length - 1)
    }

    @Test func matchesFromClosingBracket() {
        let text = "[1, 2]"
        let close = (text as NSString).range(of: "]").location
        let match = BracketMatcher.match(aroundUTF16Offset: close + 1, in: text)
        #expect(match != nil)
        #expect(match?.open.location == 0)
        #expect(match?.close.location == close)
    }

    @Test func noMatchReturnsNil() {
        let match = BracketMatcher.match(aroundUTF16Offset: 1, in: "abc")
        #expect(match == nil)
    }
}
