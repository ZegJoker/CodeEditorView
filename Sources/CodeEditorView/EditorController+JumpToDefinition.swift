import Foundation

// MARK: - Jump to definition (Phase 11)

extension EditorController {
    /// Jump-to-definition model (hover + jump). Hosts drive hover via content offset.
    public var jumpToDefinitionModel: JumpToDefinitionModel { _jumpToDefinitionModel }

    /// Current ⌘-hover / long-press range, if any.
    public var jumpHoveredRange: NSRange? { _jumpToDefinitionModel.hoveredRange }

    /// Whether the multi-target jump popover is showing (reuses completion UI).
    public var isJumpLinkPopoverVisible: Bool { _jumpToDefinitionModel.isShowingLinkPopover }

    /// Soft feedback when no definition is found (hosts may beep / HUD).
    public var onJumpFailed: (() -> Void)? {
        get { _onJumpFailed }
        set { _onJumpFailed = newValue }
    }

    /// Hosts scroll the caret into view (used after jump-to-definition from a floating panel).
    public var onRequestScrollToSelection: (() -> Void)? {
        get { _onRequestScrollToSelection }
        set { _onRequestScrollToSelection = newValue }
    }

    func requestScrollToSelection() {
        // Keep a scroll target so hosts that only honor ``scrollTarget`` still move.
        updateScrollTarget(containerWidth: contentSize.width > 0 ? contentSize.width : 400)
        _onRequestScrollToSelection?()
    }

    /// Install model controller back-reference (called from init).
    func installJumpToDefinitionIfNeeded() {
        _jumpToDefinitionModel.controller = self
    }

    /// Update hover for a document UTF-16 offset (macOS ⌘-hover, iOS long-press).
    public func jumpHover(atUTF16Offset location: Int) {
        guard jumpToDefinitionDelegate != nil else {
            cancelJumpHover()
            return
        }
        _jumpToDefinitionModel.hover(atUTF16Offset: location)
    }

    /// Clear hover emphasis and cancel pending hover work.
    public func cancelJumpHover() {
        _jumpToDefinitionModel.cancelHover()
    }

    /// Jump using hover range or an explicit range (⌘-click).
    public func performJumpToDefinition(at range: NSRange? = nil) {
        guard jumpToDefinitionDelegate != nil else { return }
        _jumpToDefinitionModel.performJump(at: range)
    }

    /// Jump from the primary caret (⌃⌘J / menu / accessibility).
    public func jumpToDefinition() {
        guard jumpToDefinitionDelegate != nil else { return }
        _jumpToDefinitionModel.performJumpAtCaret()
    }

    /// Resolve a ``CursorPosition`` to a UTF-16 range in the live document.
    public func rangeForCursorPosition(_ position: CursorPosition) -> NSRange? {
        let docLen = document.length

        // Prefer a non-empty UTF-16 range that still lies in the document.
        if position.range.length > 0,
           position.range.location >= 0,
           position.range.location + position.range.length <= docLen
        {
            return position.range
        }

        // Empty range with an explicit location (caret) — trust when in bounds.
        // Exception: (0,0) alone is ambiguous with “unset”; fall through to line/column.
        if position.range.length == 0,
           position.range.location > 0,
           position.range.location <= docLen
        {
            return NSRange(location: position.range.location, length: 0)
        }

        // Resolve via line + column (handles “start of document” at 0/0 and stale ranges).
        if let line = layout.lineIndex.line(atIndex: position.line) {
            let col = max(0, min(position.column, max(0, line.metrics.utf16Length)))
            let loc = min(line.utf16Offset + col, docLen)
            return NSRange(location: loc, length: 0)
        }

        if position.range.location >= 0, position.range.location <= docLen {
            let len = min(max(0, position.range.length), docLen - position.range.location)
            return NSRange(location: position.range.location, length: len)
        }
        return NSRange(location: 0, length: 0)
    }

    /// Tree-sitter identifier range if a TS provider is active.
    func identifierRangeFromTreeSitter(atUTF16Offset location: Int) -> NSRange? {
        for provider in highlightProviders {
            if let ts = provider as? TreeSitterHighlightProvider,
               let range = ts.identifierRange(atUTF16Offset: location)
            {
                return range
            }
        }
        return nil
    }

    /// Present multi-target links via the completion panel.
    func presentJumpLinkPopover(items: [JumpToDefinitionLink], anchor: CursorPosition) {
        // Cancel any typing-completion load so it cannot overwrite the popover.
        completionRequestTask?.cancel()
        completionRequestTask = nil
        // Ensure the anchor line is typeset so the panel can place near the click site.
        let width = contentSize.width > 0 ? contentSize.width : 400
        _ = layout.caretRect(atUTF16Offset: anchor.range.location, containerWidth: width)
        completionSession.setItems(items, anchor: anchor)
        notifyCompletionSessionChange()
    }

    func notifyJumpFailed() {
        _onJumpFailed?()
    }

    /// Apply selection from the jump popover (instead of typing completion).
    func applyJumpLinkIfNeeded(item: any CodeSuggestionEntry) -> Bool {
        // Prefer the concrete link object even if flags were cleared mid-click.
        if let link = item as? JumpToDefinitionLink {
            _jumpToDefinitionModel.open(link: link)
            return true
        }
        guard _jumpToDefinitionModel.isShowingLinkPopover else { return false }
        _jumpToDefinitionModel.applyLinkPopoverSelection(item)
        return true
    }
}
