import CodeEditorCore
import Foundation

/// Manages jump-to-definition hover + jump (CESE-aligned, no Combine).
///
/// - Finds an identifier range under the pointer (tree-sitter, then word fallback).
/// - Applies hover emphasis via ``EmphasisManager``.
/// - Queries ``JumpToDefinitionDelegate`` and navigates local/remote targets.
@MainActor
public final class JumpToDefinitionModel {
    public static let emphasisGroup = EmphasisGroup.jumpToDefinition

    public private(set) var hoveredRange: NSRange?

    /// When true, the completion panel is showing multi-target jump links (not typing completions).
    public private(set) var isShowingLinkPopover = false

    private var hoverRequestTask: Task<Void, Never>?
    private var jumpRequestTask: Task<Void, Never>?
    private var currentLinks: [JumpToDefinitionLink] = []

    weak var controller: EditorController?

    public init(controller: EditorController? = nil) {
        self.controller = controller
    }

    // MARK: - Hover

    /// Update hover for a UTF-16 document offset (cmd-hover / long-press).
    public func hover(atUTF16Offset location: Int) {
        guard let controller, controller.jumpToDefinitionDelegate != nil else {
            cancelHover()
            return
        }
        let length = controller.document.length
        guard location >= 0, location < max(length, 1) || (length == 0 && location == 0) else {
            cancelHover()
            return
        }
        if length == 0 {
            cancelHover()
            return
        }
        let clamped = min(location, length - 1)

        if let hovered = hoveredRange, NSLocationInRange(clamped, hovered) {
            return
        }
        if let hovered = hoveredRange, !NSLocationInRange(clamped, hovered) {
            cancelHover()
        }

        hoverRequestTask?.cancel()
        hoverRequestTask = Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            guard let range = Self.findDefinitionRange(at: clamped, controller: controller) else {
                self.cancelHover()
                return
            }
            guard !Task.isCancelled else { return }
            self.updateHoveredRange(to: range)
        }
    }

    public func cancelHover() {
        hoverRequestTask?.cancel()
        hoverRequestTask = nil
        guard hoveredRange != nil else {
            controller?.emphasis.removeAll(in: Self.emphasisGroup)
            return
        }
        hoveredRange = nil
        controller?.emphasis.removeAll(in: Self.emphasisGroup)
        controller?.onNeedsDisplay?()
    }

    private func updateHoveredRange(to newRange: NSRange) {
        // Never paint a huge hover span (avoids underlining the rest of the document).
        let maxHoverLen = 64
        var range = newRange
        if range.length > maxHoverLen {
            range = NSRange(location: range.location, length: maxHoverLen)
        }
        hoveredRange = range
        guard let controller else { return }
        controller.emphasis.removeAll(in: Self.emphasisGroup)
        // Outline (not underline) so ⌘-hover never looks like a diagnostic squiggle
        // and does not stack with diagnostic underlines.
        controller.emphasis.add(
            Emphasis(
                range: range,
                style: .outline,
                flash: false,
                inactive: false,
                selectInDocument: false,
                group: Self.emphasisGroup
            )
        )
        controller.onNeedsDisplay?()
    }

    // MARK: - Jump

    /// Jump using the current hover range, or a provided range (e.g. caret).
    public func performJump(at range: NSRange? = nil) {
        jumpRequestTask?.cancel()
        let targetRange = range ?? hoveredRange
        guard let targetRange, let controller else {
            failJump()
            return
        }
        guard controller.jumpToDefinitionDelegate != nil else {
            failJump()
            return
        }

        jumpRequestTask = Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            self.currentLinks = []
            self.isShowingLinkPopover = false

            let links = await controller.jumpToDefinitionDelegate?
                .queryLinks(forRange: targetRange, textView: controller)
            guard !Task.isCancelled else { return }

            guard let links, !links.isEmpty else {
                self.failJump()
                return
            }

            if links.count == 1 {
                self.open(link: links[0])
                self.cancelHover()
            } else {
                self.presentLinkPopover(links: links, anchorRange: targetRange)
                self.cancelHover()
            }
        }
    }

    /// Jump from the primary caret (⌃⌘J / explicit API).
    public func performJumpAtCaret() {
        guard let controller else {
            failJump()
            return
        }
        let caret = controller.selectedRange
        // Prefer identifier covering caret, else caret range itself.
        let query: NSRange
        if let id = Self.findDefinitionRange(at: caret.location, controller: controller) {
            query = id
        } else if caret.length > 0 {
            query = caret
        } else {
            // Zero-width caret: try word at caret.
            let word = WordSelection.range(atUTF16Offset: caret.location, in: controller.document.fullString)
            query = word.length > 0 ? word : caret
        }
        performJump(at: query)
    }

    public func open(link: JumpToDefinitionLink) {
        guard let controller else { return }
        // Snapshot navigation target before dismiss clears session state.
        let isRemote = link.url != nil
        let target = link.targetRange
        // CESE: apply completion then `window?.close()`. Always dismiss the UI first,
        // even when the caret is already at the destination.
        clearLinkPopoverState()
        controller.hideCompletions()
        if isRemote {
            controller.jumpToDefinitionDelegate?.openLink(link: link)
        } else {
            openLocalLink(target: target)
        }
    }

    private func openLocalLink(target: CursorPosition) {
        guard let controller else { return }
        let resolved = controller.rangeForCursorPosition(target) ?? target.range
        let offset = max(0, min(resolved.location, controller.document.length))
        let length = max(0, min(resolved.length, controller.document.length - offset))
        let clamped = NSRange(location: offset, length: length)

        controller.expandFolds(containing: clamped.location)
        if clamped.length > 0 {
            controller.expandFolds(containing: clamped.location + clamped.length - 1)
        }
        // Always re-apply selection so jumping to the same offset again still scrolls/focuses.
        // `publishSelectionChange` updates host SwiftUI bindings via `onSelectionDidChange`.
        controller.setSelectedRange(clamped)
        // Ensure hosts consume scrollTarget (panel clicks do not go through keyDown finishSelection).
        controller.requestScrollToSelection()
        controller.onNeedsDisplay?()
    }

    private func presentLinkPopover(links: [JumpToDefinitionLink], anchorRange: NSRange) {
        guard let controller else { return }
        currentLinks = links
        isShowingLinkPopover = true
        // Anchor at the *queried symbol* (cmd-click site), not the live caret.
        let mid = max(anchorRange.location, 0)
        let anchorOffset = min(mid + max(anchorRange.length / 2, 0), max(0, controller.document.length))
        let anchor = CursorPosition.from(
            range: NSRange(location: anchorOffset, length: 0),
            lineIndex: controller.layout.lineIndex
        )
        controller.presentJumpLinkPopover(items: links, anchor: anchor)
    }

    /// Clear jump-popover flags only (panel hide is owned by ``EditorController.hideCompletions``).
    public func clearLinkPopoverState() {
        isShowingLinkPopover = false
        currentLinks = []
    }

    public func dismissLinkPopover() {
        let wasShowing = isShowingLinkPopover
        clearLinkPopoverState()
        if wasShowing {
            controller?.hideCompletions()
        }
    }

    /// Apply a selected popover row (called from completion apply path).
    public func applyLinkPopoverSelection(_ item: any CodeSuggestionEntry) {
        if let link = item as? JumpToDefinitionLink {
            open(link: link)
        } else {
            dismissLinkPopover()
        }
    }

    private func failJump() {
        cancelHover()
        dismissLinkPopover()
        controller?.notifyJumpFailed()
    }

    // MARK: - Range discovery

    /// Prefer tree-sitter identifier node; fall back to word range.
    public static func findDefinitionRange(at location: Int, controller: EditorController) -> NSRange? {
        if let ts = controller.identifierRangeFromTreeSitter(atUTF16Offset: location), ts.length > 0 {
            return ts.length <= 64 ? ts : NSRange(location: ts.location, length: 64)
        }
        let word = WordSelection.range(atUTF16Offset: location, in: controller.document.fullString)
        guard word.length > 0, word.length <= 64 else { return nil }
        // Reject pure whitespace / empty.
        let snip = (controller.document.fullString as NSString).substring(with: word)
        if snip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return word
    }
}
