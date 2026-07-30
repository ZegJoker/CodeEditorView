import Testing
import Foundation
@testable import CodeEditorCore

@Suite("Word selection")
struct WordSelectionTests {
    @Test func selectsIdentifier() {
        let doc = "func greet(_ name: String) {}"
        // offset inside "greet"
        let range = WordSelection.range(atUTF16Offset: 7, in: doc)
        #expect((doc as NSString).substring(with: range) == "greet")
    }

    @Test func selectsWordAtBoundaryAfterWord() {
        let doc = "hello world"
        // caret after "hello"
        let range = WordSelection.range(atUTF16Offset: 5, in: doc)
        #expect((doc as NSString).substring(with: range) == "hello")
    }

    @Test func underscoreInIdentifier() {
        let doc = "foo_bar baz"
        let range = WordSelection.range(atUTF16Offset: 3, in: doc)
        #expect((doc as NSString).substring(with: range) == "foo_bar")
    }

    @Test func punctuationSelectsSingleChar() {
        let doc = "a(b)"
        let range = WordSelection.range(atUTF16Offset: 1, in: doc)
        #expect((doc as NSString).substring(with: range) == "(")
    }
}
