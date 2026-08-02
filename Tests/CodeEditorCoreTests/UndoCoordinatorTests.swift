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

    /// DOC-N04: only atomic group apply is public; apply whole group as one store transaction.
    @Test func test_DOC_N04_atomicUndoGroupOnlyNoPartialMutation() throws {
        let undo = UndoCoordinator()
        let doc = DocumentStore(string: "base")
        // One multi-range transaction registered as a single undo group (content states tracked).
        let applied = try doc.apply(
            EditTransaction(
                changes: [
                    TextChange(range: NSRange(location: 0, length: 0), replacement: "A"),
                    TextChange(range: NSRange(location: 4, length: 0), replacement: "Z"),
                ],
                origin: .programmatic
            )
        )
        undo.register(applied: applied)
        #expect(doc.fullString == "AbaseZ")
        #expect(applied.textEdits.count >= 1)
        let dirtyState = doc.contentState
        let dirtyVersion = doc.version
        let cleanState = applied.beforeState

        // Failed apply with zero store mutation leaves stack AND store unchanged.
        enum Boom: Error { case failBeforeMutation }
        #expect(throws: Boom.self) {
            try undo.undoGroup { _ in throw Boom.failBeforeMutation }
        }
        #expect(undo.canUndo)
        #expect(!undo.canRedo)
        #expect(doc.fullString == "AbaseZ")
        #expect(doc.contentState == dirtyState)
        #expect(doc.version == dirtyVersion)

        // Atomic path: one DocumentStore.apply for the whole inverse group (no per-edit loop).
        let versionBeforeUndo = doc.version
        try undo.undoGroup { group in
            #expect(!group.edits.isEmpty)
            #expect(group.beforeState == cleanState)
            let changes = group.edits.map {
                TextChange(range: $0.inverse.range, replacement: $0.inverse.string)
            }
            _ = try doc.apply(
                EditTransaction(changes: changes, origin: .undo),
                sortHighToLow: false,
                restoreContentState: group.beforeState
            )
        }
        #expect(doc.fullString == "base")
        #expect(doc.contentState == cleanState)
        #expect(!undo.canUndo)
        #expect(undo.canRedo)
        // Single content generation for the whole group undo (not one version per edit).
        #expect(doc.version == DocumentVersion(rawValue: versionBeforeUndo.rawValue + 1))

        // Atomic redo restores exact group text in one generation.
        let versionBeforeRedo = doc.version
        try undo.redoGroup { group in
            let changes = group.edits.map {
                TextChange(range: $0.mutation.range, replacement: $0.mutation.string)
            }
            _ = try doc.apply(
                EditTransaction(changes: changes, origin: .redo),
                sortHighToLow: false,
                restoreContentState: group.afterState
            )
        }
        #expect(doc.fullString == "AbaseZ")
        #expect(doc.contentState == dirtyState)
        #expect(doc.version == DocumentVersion(rawValue: versionBeforeRedo.rawValue + 1))
        #expect(undo.canUndo)
        #expect(!undo.canRedo)
    }
}
