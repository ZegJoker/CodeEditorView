import Foundation
import TextStory

/// Groups text edits into undoable units without relying on Combine or UIKit/AppKit UndoManager coupling.
///
/// Only **atomic group** apply APIs are public (DOC-N04). Per-edit callbacks that can partially
/// mutate external state were removed.
@MainActor
public final class UndoCoordinator {
    /// One undoable unit: edits plus content-state endpoints for dirty tracking (DOC-N01).
    public struct RegisteredGroup: Sendable {
        public var edits: [TextEdit]
        public var beforeState: DocumentContentStateID
        public var afterState: DocumentContentStateID

        public init(
            edits: [TextEdit],
            beforeState: DocumentContentStateID,
            afterState: DocumentContentStateID
        ) {
            self.edits = edits
            self.beforeState = beforeState
            self.afterState = afterState
        }
    }

    private struct Group {
        var edits: [TextEdit]
        var beforeState: DocumentContentStateID?
        var afterState: DocumentContentStateID?
    }

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    private var openGroup: Group?
    private var isUndoing = false
    private var isRedoing = false
    private var isDisabled = false
    private var breakNextGroup = false

    public var groupingEnabled: Bool = true
    public var canUndo: Bool { !undoStack.isEmpty || (openGroup?.edits.isEmpty == false) }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init() {}

    public func beginGrouping() {
        flushOpenGroup()
        openGroup = Group(edits: [])
    }

    public func endGrouping() {
        flushOpenGroup()
        breakNextGroup = true
    }

    public func disable() { isDisabled = true }
    public func enable() { isDisabled = false }

    /// Registers a single edit. Prefer ``register(applied:)`` so content states are tracked.
    public func register(edit: TextEdit) {
        guard !isDisabled, !isUndoing, !isRedoing else { return }

        if breakNextGroup {
            flushOpenGroup()
            breakNextGroup = false
        }

        if shouldStartNewGroup(for: edit) {
            flushOpenGroup()
        }

        if openGroup == nil {
            openGroup = Group(edits: [])
        }
        openGroup?.edits.append(edit)
        redoStack.removeAll()

        if edit.replacement.contains(where: \.isNewline) {
            flushOpenGroup()
        }
    }

    /// Registers a full applied transaction as one undo group with content states (DOC-N01).
    public func register(applied: AppliedEditTransaction) {
        guard !isDisabled, !isUndoing, !isRedoing else { return }
        flushOpenGroup()
        guard !applied.textEdits.isEmpty else { return }
        undoStack.append(
            Group(
                edits: applied.textEdits,
                beforeState: applied.beforeState,
                afterState: applied.afterState
            )
        )
        redoStack.removeAll()
        breakNextGroup = true
    }

    /// Undoes the last group as a whole. `group.edits` are in **undo application order**
    /// (reverse of original registration order).
    ///
    /// Stack ownership moves only after `apply` succeeds (DOC-002 / DOC-N04). Failed application
    /// leaves both stacks unchanged. State flags are always cleared via `defer`.
    ///
    /// - Important: `apply` must treat the group as **one atomic transaction** (e.g.
    ///   `DocumentStore.apply` with all inverse ranges). Hosts must not apply edits
    ///   one-by-one with partial external mutation; there is no public per-edit undo API.
    public func undoGroup(apply: (RegisteredGroup) throws -> Void) throws {
        flushOpenGroup()
        guard let group = undoStack.last else { return }
        isUndoing = true
        defer { isUndoing = false }
        let registered = RegisteredGroup(
            edits: group.edits.reversed(),
            beforeState: group.beforeState ?? DocumentContentStateID(),
            afterState: group.afterState ?? DocumentContentStateID()
        )
        try apply(registered)
        // Commit stack transition only after successful apply.
        _ = undoStack.popLast()
        redoStack.append(group)
    }

    /// Redoes the last group as a whole. `group.edits` are in original application order.
    ///
    /// Stack ownership moves only after `apply` succeeds (DOC-002 / DOC-N04).
    /// Same atomicity rules as ``undoGroup(apply:)``.
    public func redoGroup(apply: (RegisteredGroup) throws -> Void) throws {
        flushOpenGroup()
        guard let group = redoStack.last else { return }
        isRedoing = true
        defer { isRedoing = false }
        let registered = RegisteredGroup(
            edits: group.edits,
            beforeState: group.beforeState ?? DocumentContentStateID(),
            afterState: group.afterState ?? DocumentContentStateID()
        )
        try apply(registered)
        _ = redoStack.popLast()
        undoStack.append(group)
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        openGroup = nil
    }

    private func flushOpenGroup() {
        guard let group = openGroup, !group.edits.isEmpty else {
            openGroup = nil
            return
        }
        undoStack.append(group)
        openGroup = nil
    }

    private func shouldStartNewGroup(for edit: TextEdit) -> Bool {
        guard groupingEnabled else { return openGroup == nil }
        guard let last = openGroup?.edits.last else { return false }
        // Contiguous typing stays in one group; jumps start a new group.
        let lastEnd = last.range.location + last.replacement.utf16.count
        return edit.range.location != lastEnd
    }
}
