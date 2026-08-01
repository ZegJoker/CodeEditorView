import CodeEditorCore
import CodeEditorDocuments
import Foundation

// MARK: - Versioned edit funnel

extension EditorController {
    /// Applies a content transaction with a single document version bump, detailed
    /// events, layout/highlight hooks, and optional lifecycle observers.
    ///
    /// Content is always applied through ``textDocument`` (document-scoped undo).
    /// When using a presentation mirror, the same transaction is mirrored locally
    /// for layout/highlight without a second undo registration.
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
        if isApplyingRemoteDocumentEdit { return nil }

        let preSnapshot = textDocument.snapshot()
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

        // Tree-sitter / provider pre-edit hooks.
        for change in ordered {
            noteWillEdit(change.replacedRange.nsRange)
        }

        layout.beginTransaction()
        let applied: AppliedEditTransaction
        do {
            applied = try textDocument.apply(
                normalized,
                sortHighToLow: false,
                registerUndo: registerUndo
            )
        } catch {
            layout.endTransaction()
            return nil
        }
        lastLocalTransactionID = applied.transaction.id
        lastSeenDocumentVersion = applied.newVersion

        // Mirror onto session-local presentation buffer when isolated from content store.
        if usesPresentationMirror {
            do {
                _ = try document.apply(normalized, sortHighToLow: false)
            } catch {
                document.setFullText(textDocument.text)
            }
        }

        for edit in applied.textEdits {
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
            noteDidEdit(range: edit.range, delta: edit.mutation.delta)
        }
        layout.endTransaction()

        updatingSelection?(applied)
        syncSessionFromController()

        events.yield(.didApplyEdit(applied))
        for observer in liveLifecycleObservers {
            observer.editorDidApply(applied)
        }

        publishTextChange()
        return applied
    }

    /// Full document replace as a single programmatic transaction (clears undo).
    func applyFullTextReplace(_ string: String) {
        if isApplyingRemoteDocumentEdit { return }
        let transaction = EditTransaction.single(
            range: NSRange(location: 0, length: textDocument.length),
            replacement: string,
            origin: .programmatic
        )
        let preSnapshot = textDocument.snapshot()
        events.yield(.willChangeText)
        events.yield(.willApplyEdit(transaction, preSnapshot))
        for observer in liveLifecycleObservers {
            observer.editorWillApply(transaction, snapshot: preSnapshot)
        }

        let applied: AppliedEditTransaction
        do {
            applied = try textDocument.replaceFullContent(
                string,
                origin: .programmatic,
                clearUndo: true,
                markDirty: true
            )
        } catch {
            return
        }
        lastLocalTransactionID = applied.transaction.id
        lastSeenDocumentVersion = applied.newVersion

        if usesPresentationMirror {
            document.setFullText(string)
        }

        layout.invalidateAll()
        if !languageConfigInFlight {
            highlighter?.documentDidReplaceAll()
        } else {
            highlighter?.updateHooks(makeHighlightHooks())
            highlighter?.syncDocumentLengthOnly()
        }

        selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
        syncSessionFromController()

        events.yield(.didApplyEdit(applied))
        for observer in liveLifecycleObservers {
            observer.editorDidApply(applied)
        }
        publishTextChange()
        publishSelectionChange()
    }
}
