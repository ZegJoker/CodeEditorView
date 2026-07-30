import Testing
import Foundation
import TextStory
@testable import CodeEditorCore

@Suite("UndoCoordinator")
@MainActor
struct UndoCoordinatorTests {
    @Test func groupsContiguousTyping() {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "")

        for ch in ["a", "b", "c"] {
            let edit = doc.replaceCharacters(
                in: NSRange(location: doc.length, length: 0),
                with: ch
            )
            undo.register(edit: edit)
        }

        var applied: [String] = []
        undo.undo { edit in
            doc.applyMutation(edit.inverse)
            applied.append(edit.inverse.string)
        }
        #expect(doc.fullString == "")
        #expect(applied.count == 3)
    }

    @Test func redoRestores() {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "x")
        let edit = doc.replaceCharacters(in: NSRange(location: 1, length: 0), with: "y")
        undo.register(edit: edit)
        undo.undo { doc.applyMutation($0.inverse) }
        #expect(doc.fullString == "x")
        undo.redo { doc.applyMutation($0.mutation) }
        #expect(doc.fullString == "xy")
    }
}
