import Foundation
import Testing

@testable import CodeEditorCore

@Suite("MultiRange")
struct MultiRangeTests {
    @Test func remapAfterInsert() {
        let range = NSRange(location: 10, length: 5)
        let remapped = MultiRangeEdit.remap(range: range, editLocation: 5, delta: 3)
        #expect(remapped.location == 13)
        #expect(remapped.length == 5)
    }

    @Test func remapBeforeUnchanged() {
        let range = NSRange(location: 2, length: 2)
        let remapped = MultiRangeEdit.remap(range: range, editLocation: 10, delta: 5)
        #expect(remapped == range)
    }

    @Test func normalizeMergesOverlaps() {
        let ranges = [
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 4),
            NSRange(location: 20, length: 1),
        ]
        let normalized = MultiRangeEdit.normalize(ranges, documentLength: 100)
        #expect(normalized.count == 2)
        #expect(normalized[0] == NSRange(location: 0, length: 7))
    }
}
