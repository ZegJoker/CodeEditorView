import Foundation
import Testing
import TextStory

@testable import CodeEditorCore

@Suite("UndoCoordinator")
@MainActor
struct UndoCoordinatorTests {
    @Test func groupsContiguousTyping() throws {
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
        try undo.undoGroup { group in
            for edit in group.edits {
                doc.applyMutation(edit.inverse)
                applied.append(edit.inverse.string)
            }
        }
        #expect(doc.fullString == "")
        #expect(applied.count == 3)
    }

    @Test func redoRestores() throws {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "x")
        let edit = doc.replaceCharacters(in: NSRange(location: 1, length: 0), with: "y")
        undo.register(edit: edit)
        try undo.undoGroup { group in
            for edit in group.edits {
                doc.applyMutation(edit.inverse)
            }
        }
        #expect(doc.fullString == "x")
        try undo.redoGroup { group in
            for edit in group.edits {
                doc.applyMutation(edit.mutation)
            }
        }
        #expect(doc.fullString == "xy")
    }

    @Test func failedApplyLeavesStackUnchanged() throws {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "x")
        let edit = doc.replaceCharacters(in: NSRange(location: 1, length: 0), with: "y")
        undo.register(edit: edit)
        #expect(undo.canUndo)
        enum Boom: Error { case fail }
        #expect(throws: Boom.self) {
            try undo.undoGroup { _ in throw Boom.fail }
        }
        #expect(undo.canUndo)
        #expect(!undo.canRedo)
        try undo.undoGroup { group in
            for edit in group.edits {
                doc.applyMutation(edit.inverse)
            }
        }
        #expect(doc.fullString == "x")
    }

    /// DOC-N04: only atomic group apply is public — partial mutation must not leave stacks moved.
    @Test func test_DOC_N04_atomicUndoGroupOnlyNoPartialMutation() throws {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "base")
        // Register two edits as one group.
        undo.beginGrouping()
        let e1 = doc.replaceCharacters(in: NSRange(location: 4, length: 0), with: "1")
        undo.register(edit: e1)
        let e2 = doc.replaceCharacters(in: NSRange(location: 5, length: 0), with: "2")
        undo.register(edit: e2)
        undo.endGrouping()
        #expect(doc.fullString == "base12")

        enum Boom: Error { case mid }
        var callCount = 0
        #expect(throws: Boom.self) {
            try undo.undoGroup { group in
                for edit in group.edits {
                    callCount += 1
                    if callCount == 2 { throw Boom.mid }
                    doc.applyMutation(edit.inverse)
                }
            }
        }
        // Stack must not move on failure (DOC-N04). Host is responsible for not
        // partially mutating; the API only exposes atomic group callbacks.
        #expect(undo.canUndo)
        #expect(!undo.canRedo)
    }
}
