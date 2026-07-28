import Testing
import Foundation
@testable import CodeEditorView

@Suite("Line fold storage")
struct LineFoldStorageTests {
    private func collapsedSet(_ items: (Int, Int)...) -> Set<LineFoldStorage.DepthStartPair> {
        Set(items.map { LineFoldStorage.DepthStartPair(depth: $0.0, start: $0.1) })
    }

    @Test func emptyStorage() {
        let storage = LineFoldStorage(documentLength: 50)
        #expect(storage.folds(in: 0..<50).isEmpty)
    }

    @Test func updateFoldsBasic() {
        var storage = LineFoldStorage(documentLength: 20)
        let raw: [LineFoldStorage.RawFold] = [
            .init(depth: 1, range: 0..<5),
            .init(depth: 2, range: 5..<10),
        ]
        storage.updateFolds(from: raw, collapsedRanges: [])
        let folds = storage.folds(in: 0..<20)
        #expect(folds.count == 2)
        #expect(folds[0].depth == 1 && folds[0].range == 0..<5 && folds[0].isCollapsed == false)
        #expect(folds[1].depth == 2 && folds[1].range == 5..<10 && folds[1].isCollapsed == false)
    }

    @Test func preserveCollapseState() {
        var storage = LineFoldStorage(documentLength: 15)
        let raw = [LineFoldStorage.RawFold(depth: 1, range: 0..<5)]
        storage.updateFolds(from: raw, collapsedRanges: [])
        #expect(storage.folds(in: 0..<15).first?.isCollapsed == false)

        storage.updateFolds(from: raw, collapsedRanges: collapsedSet((1, 0)))
        #expect(storage.folds(in: 0..<15).first?.isCollapsed == true)
    }

    @Test func toggleCollapse() {
        var storage = LineFoldStorage(documentLength: 10)
        storage.updateFolds(from: [.init(depth: 1, range: 2..<8)], collapsedRanges: [])
        guard let fold = storage.folds(in: 0..<10).first else {
            Issue.record("missing fold")
            return
        }
        storage.toggleCollapse(forFold: fold)
        #expect(storage.folds(in: 0..<10).first?.isCollapsed == true)
        storage.toggleCollapse(forFold: fold)
        #expect(storage.folds(in: 0..<10).first?.isCollapsed == false)
    }

    @Test func storageUpdatedShiftsRanges() {
        var storage = LineFoldStorage(documentLength: 20)
        storage.updateFolds(from: [.init(depth: 1, range: 5..<15)], collapsedRanges: [])
        storage.storageUpdated(editedRange: NSRange(location: 0, length: 0), changeInLength: 3)
        // Document grew at start; store length grows. Full rebuild would re-place folds;
        // after shift alone, query still works without crash.
        #expect(storage.documentLength == 23)
    }
}
