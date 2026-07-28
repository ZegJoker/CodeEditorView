import Testing
@testable import CodeEditorView

@Suite("Suggestion trigger")
struct SuggestionTriggerTests {
    @Test func lettersAndDigitsTrigger() {
        #expect(SuggestionTrigger.shouldPresent(afterInserting: "a", triggerCharacters: []) == true)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: "9", triggerCharacters: []) == true)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: "foo", triggerCharacters: []) == true)
    }

    @Test func triggerCharacters() {
        #expect(SuggestionTrigger.shouldPresent(afterInserting: ".", triggerCharacters: ["."]) == true)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: ".", triggerCharacters: []) == false)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: ":", triggerCharacters: [":", "."]) == true)
    }

    @Test func emptyOrWhitespaceDoesNotTrigger() {
        #expect(SuggestionTrigger.shouldPresent(afterInserting: "", triggerCharacters: ["."]) == false)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: " ", triggerCharacters: []) == false)
        #expect(SuggestionTrigger.shouldPresent(afterInserting: "\n", triggerCharacters: []) == false)
    }
}
