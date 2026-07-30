import Foundation

// MARK: - Find & replace (Phase 7)

extension EditorController {
    // MARK: Panel visibility

    /// Shows the find panel. Optionally seeds the query from a single-line selection.
    ///
    /// - Find mode (⌘F): focuses the find field; selects existing query when non-empty.
    /// - Replace mode (⌘R): focuses the **replace** field so the user can type the replacement.
    public func showFindPanel(mode: FindPanelMode = .find) {
        if findSession.isShowing {
            findSession.mode = mode
            findSession.isPanelFocused = true
            if !findSession.findText.isEmpty {
                recomputeFindMatches(selectCurrent: false, flashCurrent: false)
                applyFindEmphases(flashCurrent: false)
            }
            requestPanelFieldFocus(for: mode)
            notifyFindSessionChange()
            return
        }

        findSession.mode = mode
        findSession.isShowing = true
        findSession.isPanelFocused = true

        // Seed find query from selection when non-empty and single-line.
        let sel = selectedRange
        if sel.length > 0, let piece = document.substring(from: sel), !piece.contains("\n"), !piece.contains("\r") {
            findSession.findText = piece
        }

        if !findSession.findText.isEmpty {
            recomputeFindMatches(selectCurrent: true, flashCurrent: false)
            applyFindEmphases(flashCurrent: false)
        }
        requestPanelFieldFocus(for: mode)
        notifyFindSessionChange()
    }

    /// Expands an already-visible find panel into replace mode (⌘R), or shows replace if hidden.
    /// Focuses the replace field so the user can type the replacement immediately.
    public func showReplacePanel() {
        showFindPanel(mode: .replace)
    }

    /// Requests a panel text field take focus for the given mode.
    public func requestPanelFieldFocus(for mode: FindPanelMode) {
        switch mode {
        case .find:
            findSession.fieldFocusTarget = .find
            findSession.selectFieldTextOnFocus = !findSession.findText.isEmpty
        case .replace:
            findSession.fieldFocusTarget = .replace
            findSession.selectFieldTextOnFocus = !findSession.replaceText.isEmpty
        }
        findSession.fieldFocusToken &+= 1
    }

    /// Requests the find text field take focus; optionally select-all the query.
    public func requestFindFieldFocus(selectQuery: Bool) {
        findSession.fieldFocusTarget = .find
        findSession.selectFieldTextOnFocus = selectQuery
        findSession.fieldFocusToken &+= 1
    }

    public func hideFindPanel() {
        guard findSession.isShowing else { return }
        findSession.isShowing = false
        findSession.isPanelFocused = false
        clearFindEmphases()
        notifyFindSessionChange()
    }

    public func setFindPanelFocused(_ focused: Bool) {
        guard findSession.isPanelFocused != focused else { return }
        findSession.isPanelFocused = focused
        if focused {
            if !findSession.findText.isEmpty {
                applyFindEmphases(flashCurrent: false)
            }
        } else {
            // Keep match highlights while the panel is open; only clear when hidden.
            // (Unfocus used to clear + notify, which re-entered panel UI and re-stole key focus.)
        }
        // Avoid a full notify cycle on unfocus — that rebuilt the panel and re-focused fields.
        if focused {
            notifyFindSessionChange()
        } else {
            onNeedsDisplay?()
        }
    }

    // MARK: Query / options

    public func setFindQuery(_ text: String) {
        guard findSession.findText != text else { return }
        findSession.findText = text
        if text.isEmpty {
            findSession.matches = []
            findSession.currentMatchIndex = nil
            clearFindEmphases()
        } else {
            recomputeFindMatches(selectCurrent: true, flashCurrent: false)
            if findSession.isPanelFocused {
                applyFindEmphases(flashCurrent: false)
            }
        }
        notifyFindSessionChange()
    }

    public func setReplaceText(_ text: String) {
        guard findSession.replaceText != text else { return }
        findSession.replaceText = text
        notifyFindSessionChange()
    }

    public func setFindMethod(_ method: FindMethod) {
        guard findSession.method != method else { return }
        findSession.method = method
        if !findSession.findText.isEmpty {
            recomputeFindMatches(selectCurrent: true, flashCurrent: false)
            if findSession.isPanelFocused {
                applyFindEmphases(flashCurrent: false)
            }
        }
        notifyFindSessionChange()
    }

    public func setMatchCase(_ enabled: Bool) {
        guard findSession.matchCase != enabled else { return }
        findSession.matchCase = enabled
        if !findSession.findText.isEmpty {
            recomputeFindMatches(selectCurrent: true, flashCurrent: false)
            if findSession.isPanelFocused {
                applyFindEmphases(flashCurrent: false)
            }
        }
        notifyFindSessionChange()
    }

    public func setWrapAround(_ enabled: Bool) {
        guard findSession.wrapAround != enabled else { return }
        findSession.wrapAround = enabled
        notifyFindSessionChange()
    }

    public func setFindPanelMode(_ mode: FindPanelMode) {
        guard findSession.mode != mode else { return }
        findSession.mode = mode
        notifyFindSessionChange()
    }

    // MARK: Navigation

    public func findNext() {
        moveFindMatch(forwards: true)
    }

    public func findPrevious() {
        moveFindMatch(forwards: false)
    }

    private func moveFindMatch(forwards: Bool) {
        if findSession.matches.isEmpty, !findSession.findText.isEmpty {
            recomputeFindMatches(selectCurrent: true, flashCurrent: false)
        }
        guard !findSession.matches.isEmpty else {
            notifyFindSessionChange()
            return
        }

        defer {
            applyFindEmphases(flashCurrent: true)
            selectCurrentFindMatch(scroll: true)
            notifyFindSessionChange()
        }

        guard let current = findSession.currentMatchIndex else {
            findSession.currentMatchIndex = 0
            return
        }

        let atLimit = forwards
            ? current == findSession.matches.count - 1
            : current == 0
        if atLimit, !findSession.wrapAround {
            return
        }
        if forwards {
            findSession.currentMatchIndex = (current + 1) % findSession.matches.count
        } else {
            findSession.currentMatchIndex =
                (current - 1 + findSession.matches.count) % findSession.matches.count
        }
    }

    // MARK: Replace

    public func replaceCurrentMatch() {
        guard configuration.isEditable,
              let index = findSession.currentMatchIndex,
              findSession.matches.indices.contains(index)
        else { return }

        var matches = findSession.matches
        let range = matches[index]
        let replacement = findSession.replaceText

        // Mutate document without letting publishTextChange recompute matches mid-replace.
        isApplyingFindReplace = true
        replaceCharacters(in: range, with: replacement)
        isApplyingFindReplace = false

        // Shift later match locations by the UTF-16 delta (longer replacement → later).
        let lengthDiff = replacement.utf16.count - range.length
        matches.remove(at: index)
        for i in matches.indices where matches[i].location > range.location {
            matches[i] = NSRange(
                location: matches[i].location + lengthDiff,
                length: matches[i].length
            )
        }
        findSession.matches = matches
        if matches.isEmpty {
            findSession.currentMatchIndex = nil
        } else if findSession.wrapAround {
            findSession.currentMatchIndex = index % matches.count
        } else {
            findSession.currentMatchIndex = min(index, matches.count - 1)
        }
        applyFindEmphases(flashCurrent: true)
        selectCurrentFindMatch(scroll: true)
        notifyFindSessionChange()
    }

    public func replaceAllMatches() {
        guard configuration.isEditable, !findSession.matches.isEmpty else { return }

        let sorted = findSession.matches.sorted { $0.location < $1.location }
        let replacement = findSession.replaceText
        let highToLow = sorted.reversed().map { TextChange(range: $0, replacement: replacement) }
        let lastLocation = sorted.last?.location ?? 0
        isApplyingFindReplace = true
        let transaction = EditTransaction(changes: Array(highToLow), origin: .programmatic)
        _ = applyEditTransaction(transaction) { _ in
            self.selection.setSelectedRange(
                NSRange(location: lastLocation + replacement.utf16.count, length: 0)
            )
            self.updateScrollTarget(containerWidth: self.contentSize.width > 0 ? self.contentSize.width : 400)
        }
        isApplyingFindReplace = false

        findSession.matches = []
        findSession.currentMatchIndex = nil
        clearFindEmphases()
        publishSelectionChange()
        notifyFindSessionChange()
    }

    // MARK: Apply inbound EditorState

    /// Applies host-driven find fields from ``EditorState`` (two-way binding).
    public func applyFindStateFromEditorState(_ state: EditorState) {
        if let visible = state.findPanelVisible {
            if visible, !findSession.isShowing {
                showFindPanel(mode: findSession.mode)
            } else if !visible, findSession.isShowing {
                hideFindPanel()
            }
        }
        if let text = state.findText, text != findSession.findText {
            setFindQuery(text)
        }
        if let text = state.replaceText, text != findSession.replaceText {
            setReplaceText(text)
        }
    }

    // MARK: Internals

    func recomputeFindMatches(selectCurrent: Bool, flashCurrent: Bool) {
        let matches = FindEngine.matches(
            in: document.fullString,
            query: findSession.findText,
            method: findSession.method,
            matchCase: findSession.matchCase
        )
        findSession.matches = matches
        if matches.isEmpty {
            findSession.currentMatchIndex = nil
        } else if selectCurrent {
            let caret = selectedRange.location
            findSession.currentMatchIndex = FindEngine.nearestMatchIndex(matches: matches, toCaret: caret)
                ?? 0
        } else if let current = findSession.currentMatchIndex {
            findSession.currentMatchIndex = min(current, matches.count - 1)
        } else {
            findSession.currentMatchIndex = 0
        }
        _ = flashCurrent
    }

    func applyFindEmphases(flashCurrent: Bool) {
        emphasis.removeAll(in: EmphasisGroup.find)
        guard findSession.isShowing, findSession.isPanelFocused, !findSession.matches.isEmpty else {
            return
        }
        let current = findSession.currentMatchIndex
        for (index, range) in findSession.matches.enumerated() {
            let isCurrent = index == current
            emphasis.add(
                Emphasis(
                    range: range,
                    style: .standard,
                    flash: flashCurrent && isCurrent,
                    inactive: !isCurrent,
                    selectInDocument: false,
                    group: EmphasisGroup.find
                )
            )
        }
    }

    func clearFindEmphases() {
        emphasis.removeAll(in: EmphasisGroup.find)
    }

    func selectCurrentFindMatch(scroll: Bool) {
        guard let match = findSession.currentMatch else { return }
        // Expand any collapsed folds so the match is visible.
        expandFolds(containing: match.location)
        selection.setSelectedRange(match)
        if scroll {
            updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        }
        publishSelectionChange()
    }
}
