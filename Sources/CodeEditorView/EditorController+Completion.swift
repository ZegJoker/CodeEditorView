import Foundation

// MARK: - Code completion (Phase 8)

extension EditorController {
    public var completionsVisible: Bool { completionSession.isVisible }

    /// Opens the completion list (async load via the delegate).
    public func showCompletions() {
        guard let delegate = completionDelegate else { return }
        // Do not open typing completions over an active jump-to-definition popover.
        if isJumpLinkPopoverVisible { return }
        let cursors = cursorPositions
        guard let primary = cursors.first else { return }

        completionRequestTask?.cancel()
        let controller = self
        completionRequestTask = Task { @MainActor in
            defer { controller.completionRequestTask = nil }
            guard !controller.isJumpLinkPopoverVisible else { return }
            guard let result = await delegate.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: primary
            ) else {
                return
            }
            guard !Task.isCancelled, !controller.isJumpLinkPopoverVisible else { return }
            if result.items.isEmpty {
                controller.hideCompletions()
                return
            }
            controller.completionSession.setItems(result.items, anchor: result.windowPosition)
            controller.completionSession.selectIndex(0)
            controller.notifyCompletionSessionChange()
        }
    }

    public func hideCompletions() {
        let wasJumpPopover = isJumpLinkPopoverVisible
        let wasVisible = completionSession.isVisible
        completionRequestTask?.cancel()
        completionRequestTask = nil
        // Clear jump flags first so dismissLinkPopover does not re-enter hide.
        if wasJumpPopover {
            _jumpToDefinitionModel.clearLinkPopoverState()
        }
        completionSession.setVisible(false)
        if wasVisible {
            if !wasJumpPopover {
                completionDelegate?.completionWindowDidClose()
            }
            notifyCompletionSessionChange()
        }
    }

    public func moveCompletionSelection(delta: Int) {
        guard completionSession.isVisible else { return }
        completionSession.moveSelection(delta: delta)
        if !isJumpLinkPopoverVisible, let item = completionSession.selectedItem {
            completionDelegate?.completionWindowDidSelect(item: item)
        }
        notifyCompletionSessionChange()
    }

    public func selectCompletionIndex(_ index: Int) {
        guard completionSession.isVisible else { return }
        completionSession.selectIndex(index)
        if !isJumpLinkPopoverVisible, let item = completionSession.selectedItem {
            completionDelegate?.completionWindowDidSelect(item: item)
        }
        notifyCompletionSessionChange()
    }

    public func applyCompletionSelection() {
        // Capture item before any dismiss clears the session.
        guard let item = completionSession.selectedItem else {
            hideCompletions()
            return
        }
        // Multi-target jump-to-definition popover reuses this UI.
        if isJumpLinkPopoverVisible {
            _ = applyJumpLinkIfNeeded(item: item)
            return
        }
        guard let delegate = completionDelegate else {
            hideCompletions()
            return
        }
        let cursor = cursorPositions.first
        delegate.completionWindowApplyCompletion(
            item: item,
            textView: self,
            cursorPosition: cursor
        )
        hideCompletions()
    }

    /// Call after a successful text insert to open/filter completions.
    func noteTextInsertedForCompletions(_ inserted: String) {
        guard let delegate = completionDelegate else { return }
        if isJumpLinkPopoverVisible { return }
        let triggers = delegate.completionTriggerCharacters()
        guard SuggestionTrigger.shouldPresent(afterInserting: inserted, triggerCharacters: triggers) else {
            // Deleting or non-trigger insert: filter if already open.
            if completionSession.isVisible {
                noteCursorMovedForCompletions()
            }
            return
        }
        if completionSession.isVisible {
            noteCursorMovedForCompletions(presentIfClosed: false)
        } else {
            showCompletions()
        }
    }

    /// Sync filter while the popup is open (or optionally present).
    func noteCursorMovedForCompletions(presentIfClosed: Bool = false) {
        guard let delegate = completionDelegate else { return }
        // Jump popover owns the session — never refilter as typing completions.
        if isJumpLinkPopoverVisible { return }
        // While an async open is in-flight, ignore move (CESE).
        if completionRequestTask != nil { return }

        guard completionSession.isVisible || presentIfClosed else { return }
        guard let primary = cursorPositions.first else {
            hideCompletions()
            return
        }

        if !completionSession.isVisible, presentIfClosed {
            showCompletions()
            return
        }

        guard let items = delegate.completionOnCursorMove(textView: self, cursorPosition: primary),
              !items.isEmpty
        else {
            hideCompletions()
            return
        }
        completionSession.setItems(items, anchor: primary)
        notifyCompletionSessionChange()
    }

    func notifyCompletionSessionChange() {
        onCompletionSessionChange?()
        onNeedsDisplay?()
    }
}
