# ADR-003: Shared documents and editor sessions

## Status

Accepted (Phase 4)

## Context

Phase 3 introduced versioned edits on `DocumentStore`. Hosts still needed a model where one buffer can power multiple editor views with independent selection, scroll, find, and theme, plus document-scoped undo, dirty/URI metadata, and load/save providers.

## Decision

1. **`CodeEditorDocuments` product** — platform-neutral types above `CodeEditorCore`.
2. **`TextDocument`** — shared content authority: `DocumentStore`, document-scoped `UndoCoordinator`, `DocumentVersion`, dirty flag, URI, encoding, event stream.
3. **`EditorSession`** — presentation identity: selections, scroll, find state (not theme types from View).
4. **`DocumentRegistry`** — open-document lookup by id/URI.
5. **Providers** — `DocumentContentProvider` with `InMemoryDocumentProvider` and `LocalFileDocumentProvider`.
6. **Presentation isolation** — when an `EditorController` is created with a shared document + session, it uses a **session-local** `DocumentStore` mirror for attributes/typesetting. Content mutations go through `TextDocument`; remote sessions observe `TextDocumentEvent.didApply` and mirror text + remap selection.
7. **Standalone path** — `EditorController(text:)` creates a private `TextDocument` and uses `textDocument.store` as the presentation buffer (zero extra copy).
8. **SwiftUI** — keep `CodeEditor(text:)` bindings; add `SharedCodeEditor` / `CodeEditor.shared(document:session:)`.

## Consequences

- Undo is always document-scoped (`textDocument.undo` / `performUndo`).
- Two themes can paint the same document without clobbering each other.
- Hosts must attach a session per view for multi-view sharing.
- Full draw-time decoration without attributed strings remains a future optimization; Phase 4 isolates paint via presentation mirrors.
