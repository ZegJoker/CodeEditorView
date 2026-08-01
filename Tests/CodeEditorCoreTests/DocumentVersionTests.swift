import Foundation
import Testing

@testable import CodeEditorCore

@Suite("Document versioning")
struct DocumentVersionTests {
    @Test func contentMutationBumpsVersionOnce() throws {
        let store = DocumentStore(string: "hello")
        #expect(store.version == .zero)

        let edit = store.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
        #expect(edit.replacement == "!")
        #expect(store.version == DocumentVersion(rawValue: 1))
        #expect(store.fullString == "hello!")
    }

    @Test func attributeOnlyDoesNotBumpVersion() {
        let store = DocumentStore(string: "abc")
        let before = store.version
        store.setAttributes([.foregroundColor: "x"], range: NSRange(location: 0, length: 3))
        store.resetAttributesToDefaults()
        #expect(store.version == before)
    }

    @Test func snapshotIsStableAfterFurtherEdits() {
        let store = DocumentStore(string: "one")
        _ = store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "")
        let snap = store.snapshot()
        #expect(snap.text == "one")
        #expect(snap.version == store.version)

        _ = store.replaceCharacters(in: NSRange(location: 0, length: 3), with: "two")
        #expect(snap.text == "one")
        #expect(snap.version.rawValue + 1 == store.version.rawValue)
        #expect(store.fullString == "two")
    }

    @Test func multiChangeTransactionSingleVersionBump() throws {
        let store = DocumentStore(string: "abcdef")
        let before = store.version
        let tx = EditTransaction(
            changes: [
                TextChange(range: NSRange(location: 3, length: 1), replacement: "X"),  // d
                TextChange(range: NSRange(location: 0, length: 1), replacement: "A"),  // a
            ],
            origin: .programmatic
        )
        let applied = try store.apply(tx)
        #expect(applied.oldVersion == before)
        #expect(applied.newVersion == before.advanced())
        #expect(store.version == applied.newVersion)
        #expect(store.fullString == "AbcXef")
    }

    @Test func inverseRestoresTextAndAdvancesVersion() throws {
        let store = DocumentStore(string: "hello")
        let tx = EditTransaction.single(
            range: NSRange(location: 0, length: 5),
            replacement: "world",
            origin: .typing
        )
        let applied = try store.apply(tx)
        #expect(store.fullString == "world")
        let mid = store.version

        let undone = try store.apply(applied.inverse, sortHighToLow: false)
        #expect(store.fullString == "hello")
        #expect(undone.newVersion > mid)
        #expect(store.version == undone.newVersion)
    }

    @Test func textPositionAndRangeAdapters() {
        let range = TextRange(NSRange(location: 2, length: 3))
        #expect(range.location == 2)
        #expect(range.length == 3)
        #expect(range.nsRange == NSRange(location: 2, length: 3))
        #expect(TextPosition(utf16Offset: 5) > TextPosition(utf16Offset: 2))
    }
}
