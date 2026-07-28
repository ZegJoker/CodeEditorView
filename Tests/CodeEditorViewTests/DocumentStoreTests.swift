import Testing
import Foundation
@testable import CodeEditorView

@Suite("DocumentStore")
@MainActor
struct DocumentStoreTests {
    @Test func replaceAndInverse() {
        let doc = DocumentStore(string: "hello world")
        let edit = doc.replaceCharacters(in: NSRange(location: 6, length: 5), with: "there")
        #expect(doc.fullString == "hello there")
        #expect(edit.inverse.string == "world")

        doc.applyMutation(edit.inverse)
        #expect(doc.fullString == "hello world")
    }

    @Test func lineEndingDetection() {
        #expect(LineEnding.detect(in: "a\nb\n") == .lineFeed)
        #expect(LineEnding.detect(in: "a\r\nb\r\n") == .carriageReturnLineFeed)
        #expect(LineEnding.detect(in: "a\rb\r") == .carriageReturn)
    }
}
