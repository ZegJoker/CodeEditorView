import Foundation

/// Pure helpers for deciding when typed text should open/filter completions.
public enum SuggestionTrigger: Sendable {
    /// Whether `inserted` (post-edit payload) should trigger the completion UI.
    ///
    /// CESE opens on letters, digits, or app trigger characters, only for non-empty inserts.
    public static func shouldPresent(
        afterInserting inserted: String,
        triggerCharacters: Set<String>
    ) -> Bool {
        guard !inserted.isEmpty, let last = inserted.last else { return false }
        if last.isLetter || last.isNumber { return true }
        return triggerCharacters.contains(String(last))
    }
}
