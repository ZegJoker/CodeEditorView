import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

@Suite("TreeSitter incremental edits")
@MainActor
struct TreeSitterEditTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func pointAtStartAndAfterNewline() {
        let text = "ab\nc" as NSString
        let p0 = TreeSitterEdit.point(atUTF16Offset: 0, in: text)
        #expect(p0.row == 0)
        #expect(p0.column == 0)

        let pNL = TreeSitterEdit.point(atUTF16Offset: 3, in: text)  // start of "c"
        #expect(pNL.row == 1)
        #expect(pNL.column == 0)

        let pEnd = TreeSitterEdit.point(atUTF16Offset: 4, in: text)
        #expect(pEnd.row == 1)
        #expect(pEnd.column == 2)  // one UTF-16 unit * 2 bytes
    }

    @Test func inputEditBytesUseUTF16() {
        let old = "hello"
        let new = "heXXlo"
        // Replace "ll" (loc 2, len 2) with "XX" (delta 0)
        let edit = TreeSitterEdit.make(
            range: NSRange(location: 2, length: 2),
            delta: 0,
            oldSource: old,
            newSource: new
        )
        #expect(edit.startByte == 4)
        #expect(edit.oldEndByte == 8)
        #expect(edit.newEndByte == 8)
    }

    @Test func incrementalEditKeepsHighlighting() async throws {
        let provider = try TreeSitterHighlightProvider(language: .swift)
        let initial = "let a = 1"
        await provider.setDocumentText(initial)

        let before = try await provider.queryHighlights(
            in: NSRange(location: 0, length: initial.utf16.count),
            text: initial
        )
        #expect(!before.isEmpty)

        // Insert "x" after "let " → "let xa = 1"
        let range = NSRange(location: 4, length: 0)
        let delta = 1
        let updated = "let xa = 1"
        provider.willApplyEdit(range: range)
        await provider.setDocumentText(updated)
        let invalid = try await provider.applyEdit(range: range, delta: delta)
        #expect(!invalid.isEmpty)

        let after = try await provider.queryHighlights(
            in: NSRange(location: 0, length: updated.utf16.count),
            text: updated
        )
        #expect(!after.isEmpty)
        let hasKeyword = after.contains {
            $0.capture == .keyword || ($0.rawCapture?.contains("keyword") == true)
        }
        #expect(hasKeyword)
    }

    @Test func sequentialEditsRemainConsistent() async throws {
        let provider = try TreeSitterHighlightProvider(language: .json)
        var text = #"{"a":1}"#
        await provider.setDocumentText(text)

        // Insert space after `{`
        provider.willApplyEdit(range: NSRange(location: 1, length: 0))
        text = #"{ "a":1}"#
        await provider.setDocumentText(text)
        _ = try await provider.applyEdit(range: NSRange(location: 1, length: 0), delta: 1)

        // Insert space before `}`
        let loc = (text as NSString).length - 1
        provider.willApplyEdit(range: NSRange(location: loc, length: 0))
        text = #"{ "a":1 }"#
        await provider.setDocumentText(text)
        _ = try await provider.applyEdit(range: NSRange(location: loc, length: 0), delta: 1)

        let highlights = try await provider.queryHighlights(
            in: NSRange(location: 0, length: (text as NSString).length),
            text: text
        )
        #expect(!highlights.isEmpty)
    }
}
