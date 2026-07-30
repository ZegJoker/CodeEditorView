import Foundation
import CodeEditorCore

// MARK: - Versioned edit funnel

extension EditorController {
    /// Applies a content transaction with a single document version bump, detailed
    /// events, layout/highlight hooks, and optional lifecycle observers.
    ///
    /// - Parameters:
    ///   - transaction: Changes in any order (sorted high→low on apply unless `sortHighToLow` is false).
    ///   - sortHighToLow: Pass `false` for ordered undo/redo sequences.
    ///   - registerUndo: When false (undo/redo), skips undo registration.
    ///   - requireEditable: When false, allows undo/redo while not editable.
    ///   - updatingSelection: Called after content apply, before text/selection publish.
    @discardableResult
    func applyEditTransaction(
        _ transaction: EditTransaction,
        sortHighToLow: Bool = true,
        registerUndo: Bool = true,
        requireEditable: Bool = true,
        updatingSelection: ((AppliedEditTransaction) -> Void)? = nil
    ) -> AppliedEditTransaction? {
        guard !transaction.changes.isEmpty else { return nil }
        if requireEditable, !configuration.isEditable { return nil }

        let preSnapshot = document.snapshot()
        let ordered: [TextChange]
        if sortHighToLow {
            ordered = transaction.changes.sorted {
                $0.replacedRange.location > $1.replacedRange.location
            }
        } else {
            ordered = transaction.changes
        }
        let normalized = EditTransaction(
            id: transaction.id,
            changes: ordered,
            origin: transaction.origin
        )

        // Legacy + versioned will-change notifications.
        events.yield(.willChangeText)
        events.yield(.willApplyEdit(normalized, preSnapshot))
        for observer in liveLifecycleObservers {
            observer.editorWillApply(normalized, snapshot: preSnapshot)
        }

        // Tree-sitter / provider pre-edit hooks (coordinates as of pre-edit / sequential step).
        for change in ordered {
            noteWillEdit(change.replacedRange.nsRange)
        }

        layout.beginTransaction()
        let applied: AppliedEditTransaction
        do {
            applied = try document.apply(normalized, sortHighToLow: false)
        } catch {
            layout.endTransaction()
            return nil
        }

        if registerUndo {
            // Multi-change transactions register as one undo group.
            if ordered.count > 1 {
                undoCoordinator.beginGrouping()
            }
            for edit in applied.textEdits {
                undoCoordinator.register(edit: edit)
            }
            if ordered.count > 1 {
                undoCoordinator.endGrouping()
            }
        }

        for edit in applied.textEdits {
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
            noteDidEdit(range: edit.range, delta: edit.mutation.delta)
        }
        layout.endTransaction()

        updatingSelection?(applied)

        events.yield(.didApplyEdit(applied))
        for observer in liveLifecycleObservers {
            observer.editorDidApply(applied)
        }

        publishTextChange()
        return applied
    }

    /// Full document replace as a single programmatic transaction (clears undo).
    func applyFullTextReplace(_ string: String) {
        let oldLength = document.length
        let range = NSRange(location: 0, length: oldLength)
        let transaction = EditTransaction.single(
            range: range,
            replacement: string,
            origin: .programmatic
        )
        let preSnapshot = document.snapshot()
        events.yield(.willChangeText)
        events.yield(.willApplyEdit(transaction, preSnapshot))
        for observer in liveLifecycleObservers {
            observer.editorWillApply(transaction, snapshot: preSnapshot)
        }

        undoCoordinator.clear()
        // setFullText bumps version once (same as a single content replace).
        let oldVersion = document.version
        document.setFullText(string)
        let newVersion = document.version
        let applied = AppliedEditTransaction(
            transaction: transaction,
            oldVersion: oldVersion,
            newVersion: newVersion,
            inverse: EditTransaction.single(
                range: NSRange(location: 0, length: (string as NSString).length),
                replacement: preSnapshot.text,
                origin: .programmatic
            ),
            textEdits: []
        )

        layout.invalidateAll()
        if !languageConfigInFlight {
            highlighter?.documentDidReplaceAll()
        } else {
            highlighter?.updateHooks(makeHighlightHooks())
            highlighter?.syncDocumentLengthOnly()
        }

        selection.setInsertionPoint(min(selection.selectedRange.location, document.length))

        events.yield(.didApplyEdit(applied))
        for observer in liveLifecycleObservers {
            observer.editorDidApply(applied)
        }
        publishTextChange()
        publishSelectionChange()
    }
}
