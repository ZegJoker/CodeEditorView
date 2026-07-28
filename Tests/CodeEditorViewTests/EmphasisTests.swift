import Testing
import Foundation
@testable import CodeEditorView

@Suite("Emphasis")
@MainActor
struct EmphasisTests {
    @Test func addAndRemove() {
        let manager = EmphasisManager()
        let emphasis = Emphasis(range: NSRange(location: 0, length: 3), style: .outline)
        manager.add(emphasis)
        #expect(manager.items.count == 1)
        manager.remove(id: emphasis.id)
        #expect(manager.items.isEmpty)
    }

    @Test func groupRemoval() {
        let manager = EmphasisManager()
        manager.add(Emphasis(range: NSRange(location: 0, length: 1), group: "find"))
        manager.add(Emphasis(range: NSRange(location: 2, length: 1), group: "find"))
        manager.add(Emphasis(range: NSRange(location: 4, length: 1), group: "other"))
        manager.removeAll(in: "find")
        #expect(manager.items.count == 1)
        #expect(manager.items[0].group == "other")
    }
}
