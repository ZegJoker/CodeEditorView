import Foundation

/// High-level editor notifications delivered through structured concurrency streams.
///
/// Legacy cases (`willChangeText`, `textDidChange`, `selectionDidChange`) remain for
/// existing consumers. Prefer the versioned `willApplyEdit` / `didApplyEdit` /
/// `selectionDidChangeDetailed` cases for LSP-style and provider-safe work.
public enum EditorEvent: Sendable, Equatable {
    /// Legacy: text is about to change (no payload).
    case willChangeText
    /// Legacy: text did change (no payload).
    case textDidChange
    /// Legacy: selection did change (no payload).
    case selectionDidChange

    /// Pre-edit snapshot and the transaction about to be applied.
    case willApplyEdit(EditTransaction, DocumentSnapshot)
    /// Post-edit result including versions and inverse.
    case didApplyEdit(AppliedEditTransaction)
    /// Selection change with UTF-16 ranges and current document version.
    case selectionDidChangeDetailed(SelectionChangeEvent)
}
