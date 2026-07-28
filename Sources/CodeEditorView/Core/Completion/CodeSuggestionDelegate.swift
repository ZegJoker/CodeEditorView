import Foundation

/// App-supplied completion provider (CESE-aligned, no Combine).
///
/// The editor owns UI and lifecycle; the delegate supplies and applies items.
@MainActor
public protocol CodeSuggestionDelegate: AnyObject {
    /// Characters that should open completions after typing (in addition to letters/digits).
    func completionTriggerCharacters() -> Set<String>

    /// Async full load when the completion UI is opened (manual or trigger).
    ///
    /// - Returns: Anchor cursor for window placement plus items, or `nil` to show nothing.
    func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])?

    /// Synchronous filter while the popup is open and the caret moves.
    /// Return `nil` or `[]` to close the popup. Must stay fast (no network).
    func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]?

    /// Insert/replace text for the chosen item (delegate owns prefix logic).
    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    )

    func completionWindowDidClose()
    func completionWindowDidSelect(item: any CodeSuggestionEntry)
}

@MainActor
public extension CodeSuggestionDelegate {
    func completionTriggerCharacters() -> Set<String> { [] }
    func completionWindowDidClose() {}
    func completionWindowDidSelect(item: any CodeSuggestionEntry) {}
}
