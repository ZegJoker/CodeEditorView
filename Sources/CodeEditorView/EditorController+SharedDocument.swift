import Foundation
import CodeEditorCore
import CodeEditorDocuments

// MARK: - Shared TextDocument / EditorSession

extension EditorController {
    /// Whether presentation paint attributes are isolated from the shared content store.
    var usesPresentationMirror: Bool {
        document !== textDocument.store
    }

    /// Subscribe to shared document events so remote sessions stay in sync.
    func startObservingSharedDocumentIfNeeded() {
        guard usesPresentationMirror else { return }
        guard documentObservationTask == nil else { return }
        let stream = textDocument.makeEventStream()
        documentObservationTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleTextDocumentEvent(event)
            }
        }
    }

    func stopObservingSharedDocument() {
        documentObservationTask?.cancel()
        documentObservationTask = nil
    }

    func handleTextDocumentEvent(_ event: TextDocumentEvent) {
        switch event {
        case .willApply:
            break
        case .didApply(let applied):
            // Skip echoes of applies we just performed on this controller.
            if applied.transaction.id == lastLocalTransactionID {
                lastSeenDocumentVersion = applied.newVersion
                return
            }
            guard applied.newVersion > lastSeenDocumentVersion else { return }
            applyRemoteTransaction(applied)
        case .externalContentReplace(let snapshot):
            applyRemoteFullReplace(snapshot.text)
        case .dirtyStateDidChange, .uriDidChange:
            break
        }
    }

    /// Mirror a remote transaction onto the session-local presentation buffer and layout.
    func applyRemoteTransaction(_ applied: AppliedEditTransaction) {
        isApplyingRemoteDocumentEdit = true
        defer { isApplyingRemoteDocumentEdit = false }

        events.yield(.willChangeText)
        events.yield(.willApplyEdit(applied.transaction, document.snapshot()))

        let ordered = applied.transaction.changes
        for change in ordered {
            noteWillEdit(change.replacedRange.nsRange)
        }

        layout.beginTransaction()
        if usesPresentationMirror {
            // Keep presentation text identical to shared content.
            do {
                _ = try document.apply(applied.transaction, sortHighToLow: false)
            } catch {
                document.setFullText(textDocument.text)
            }
        }
        // Remap selections for each applied edit (application order).
        var carets = selection.selectedRanges
        for edit in applied.textEdits {
            layout.documentDidReplace(range: edit.range, delta: edit.mutation.delta)
            noteDidEdit(range: edit.range, delta: edit.mutation.delta)
            carets = MultiRangeEdit.remap(
                ranges: carets,
                editLocation: edit.range.location,
                delta: edit.mutation.delta
            )
        }
        if applied.textEdits.isEmpty {
            // Full replace style inverse/apply without textEdits.
            layout.invalidateAll()
            highlighter?.documentDidReplaceAll()
            carets = carets.map {
                let loc = min($0.location, document.length)
                return NSRange(location: loc, length: min($0.length, max(0, document.length - loc)))
            }
        }
        layout.endTransaction()
        selection.setSelectedRanges(carets)
        session?.setSelectedNSRanges(carets)
        lastSeenDocumentVersion = applied.newVersion

        events.yield(.didApplyEdit(applied))
        publishTextChange()
        publishSelectionChange()
    }

    func applyRemoteFullReplace(_ string: String) {
        isApplyingRemoteDocumentEdit = true
        defer { isApplyingRemoteDocumentEdit = false }
        events.yield(.willChangeText)
        if usesPresentationMirror {
            document.setFullText(string)
        }
        layout.invalidateAll()
        highlighter?.documentDidReplaceAll()
        selection.setInsertionPoint(min(selection.selectedRange.location, document.length))
        session?.setSelectedNSRanges(selection.selectedRanges)
        lastSeenDocumentVersion = textDocument.version
        publishTextChange()
        publishSelectionChange()
    }

    func syncSessionFromController() {
        guard let session else { return }
        session.setSelectedNSRanges(selection.selectedRanges)
        session.scrollPosition = editorState.scrollPosition
        session.findState = EditorFindState(
            findText: findSession.findText,
            replaceText: findSession.replaceText,
            isPanelVisible: findSession.isShowing
        )
    }

    func syncControllerFromSession() {
        guard let session else { return }
        selection.setSelectedRanges(session.selectedNSRanges)
        if let scroll = session.scrollPosition {
            editorState.scrollPosition = scroll
        }
        findSession.findText = session.findState.findText
        findSession.replaceText = session.findState.replaceText
        // Panel visibility is host-driven; do not force-show on attach.
    }
}
