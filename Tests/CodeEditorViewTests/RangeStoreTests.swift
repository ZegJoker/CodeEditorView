import Foundation
import Testing

@testable import CodeEditorView

@Suite("RangeStore")
struct RangeStoreTests {
    @Test func initialLength() {
        let store = RangeStore<CaptureName>(documentLength: 10)
        #expect(store.length == 10)
        let runs = store.runs(in: NSRange(location: 0, length: 10))
        #expect(runs.count == 1)
        #expect(runs[0].value == nil)
    }

    @Test func setAndQuery() {
        var store = RangeStore<CaptureName>(documentLength: 20)
        store.set(value: .keyword, for: NSRange(location: 5, length: 3))
        store.set(value: .string, for: NSRange(location: 10, length: 4))

        let middle = store.runs(in: NSRange(location: 0, length: 20))
        #expect(middle.contains { $0.value == .keyword && $0.length == 3 })
        #expect(middle.contains { $0.value == .string && $0.length == 4 })
    }

    @Test func coalesceAdjacent() {
        var store = RangeStore<CaptureName>(documentLength: 10)
        store.set(value: .comment, for: NSRange(location: 0, length: 4))
        store.set(value: .comment, for: NSRange(location: 4, length: 3))
        let runs = store.runs(in: NSRange(location: 0, length: 10))
        #expect(runs.first?.length == 7)
        #expect(runs.first?.value == .comment)
    }

    @Test func storageEditedInsertDelete() {
        var store = RangeStore<CaptureName>(documentLength: 10)
        store.set(value: .keyword, for: NSRange(location: 2, length: 4))
        // Delete 2 chars at 0
        store.storageEdited(editRange: NSRange(location: 0, length: 2), delta: -2)
        #expect(store.length == 8)
        // Insert 3 at start
        store.storageEdited(editRange: NSRange(location: 0, length: 0), delta: 3)
        #expect(store.length == 11)
    }

    @Test func replaceDocumentLength() {
        var store = RangeStore<CaptureName>(documentLength: 5)
        store.set(value: .number, for: NSRange(location: 0, length: 5))
        store.replaceDocumentLength(with: 100)
        #expect(store.length == 100)
        #expect(store.runs(in: NSRange(location: 0, length: 100)).allSatisfy { $0.value == nil })
    }
}

@Test func setValueClampsPastEndWithoutTrap() {
    var store = RangeStore<CaptureName>(documentLength: 10)
    // Range extends past EOF — must not precondition-fail.
    store.set(value: .keyword, for: NSRange(location: 5, length: 100))
    #expect(store.length == 10)
    let runs = store.runs(in: NSRange(location: 0, length: 10))
    let total = runs.reduce(0) { $0 + $1.length }
    #expect(total == 10)
}
