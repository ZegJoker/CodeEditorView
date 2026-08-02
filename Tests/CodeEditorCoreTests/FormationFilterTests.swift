import Foundation
import Testing

@testable import CodeEditorCore

@Suite("Text filters")
struct FormationFilterTests {
    @Test func expandTabSpaces() {
        #expect(TextFilters.expandTab(indent: .spaces(count: 4)) == "    ")
        #expect(TextFilters.expandTab(indent: .tab) == "\t")
    }

    @Test func autoPairInsertsCloser() {
        let result = TextFilters.autoPair(inserted: "(", nextCharacter: nil)
        #expect(result?.insert == "()")
        #expect(result?.placeCaretInside == true)
        #expect(result?.skipOver == false)
    }

    @Test func autoPairSkipOverCloser() {
        let result = TextFilters.autoPair(inserted: ")", nextCharacter: ")")
        #expect(result?.skipOver == true)
        #expect(result?.insert == "")
    }

    @Test func autoPairQuotes() {
        let open = TextFilters.autoPair(inserted: "\"", nextCharacter: nil)
        #expect(open?.insert == "\"\"")
        #expect(open?.placeCaretInside == true)

        let skip = TextFilters.autoPair(inserted: "\"", nextCharacter: "\"")
        #expect(skip?.skipOver == true)
    }

    @Test func newlineIndentCopiesWhitespace() {
        let prefix = TextFilters.indentPrefix(forNewlineAfter: "    foo", indent: .spaces(count: 4))
        #expect(prefix == "    ")
    }

    @Test func newlineIndentExtraAfterBrace() {
        let prefix = TextFilters.indentPrefix(forNewlineAfter: "func f() {", indent: .spaces(count: 4))
        #expect(prefix == "    ")
    }

    @Test func outdentLine() {
        #expect(TextFilters.outdentLine("    foo", indent: .spaces(count: 4)) == "foo")
        #expect(TextFilters.outdentLine("  foo", indent: .spaces(count: 4)) == "foo")
        #expect(TextFilters.outdentLine("foo", indent: .spaces(count: 4)) == "foo")
    }

    @Test func deleteBackwardPreviousCharacterJoinsBlankLine() {
        // CESE/CETV: at col 0 of blank in `{\n\n}`, delete previous char (first `\n`).
        let doc = "func f() {\n\n}"
        let blank = (doc as NSString).range(of: "{\n\n}").location + 2
        let range = TextFilters.deleteBackwardRange(caret: blank, in: doc, indent: .spaces(count: 4))
        #expect(range == NSRange(location: blank - 1, length: 1))
        let ns = doc as NSString
        let result = ns.replacingCharacters(in: range!, with: "")
        #expect(result == "func f() {\n}")
        // Caret after apply sits at range.location = after `{`.
        #expect(range!.location == (result as NSString).range(of: "{").location + 1)
    }

    @Test func deleteBackwardIndentUnitLikeCESE() {
        // `    |` after 4 spaces — one delete removes the whole indent unit.
        let doc = "func f() {\n    \n}"
        let afterSpaces = (doc as NSString).range(of: "    ").location + 4
        let range = TextFilters.deleteBackwardRange(caret: afterSpaces, in: doc, indent: .spaces(count: 4))
        #expect(range == NSRange(location: afterSpaces - 4, length: 4))
    }
}
