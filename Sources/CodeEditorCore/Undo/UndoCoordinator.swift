import Foundation
import TextStory

/// Groups text edits into undoable units without relying on Combine or UIKit/AppKit UndoManager coupling.
@MainActor
public final class UndoCoordinator {
    private struct Group {
        var edits: [TextEdit]
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

    public func undo(apply: (TextEdit) -> Void) {
        flushOpenGroup()
        guard let group = undoStack.popLast() else { return }
        isUndoing = true
        for edit in group.edits.reversed() {
            apply(edit)
        }
        redoStack.append(group)
        isUndoing = false
    }

    public func redo(apply: (TextEdit) -> Void) {
        flushOpenGroup()
        guard let group = redoStack.popLast() else { return }
        isRedoing = true
        for edit in group.edits {
            apply(edit)
        }
        undoStack.append(group)
        isRedoing = false
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
