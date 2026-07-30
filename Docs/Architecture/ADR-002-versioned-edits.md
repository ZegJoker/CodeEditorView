# ADR-002: Versioned edits and provider-safe events

## Status

Accepted (Phase 3)

## Context

Async highlighters, completions, and future LSP adapters need to know whether a result still matches the document that was queried. The pre-Phase-3 `EditorEvent` stream only signaled that text changed, without edit payloads or versions. `EditorCoordinator` also forced observers to retain `EditorController`.

## Decision

1. **Monotonic `DocumentVersion`**  
   Content mutations advance a `UInt64` counter. Undo/redo advance the counter further (they do not rewind it). Attribute-only paints do not change the version.

2. **`DocumentSnapshot`**  
   Immutable plain text + version + UTF-16 length, produced by `DocumentStore.snapshot()`.

3. **`EditTransaction` / `AppliedEditTransaction`**  
   All multi-range content changes for one user gesture form a single transaction with one version bump. High→low order for pre-edit multi-range coordinates; ordered sequences for undo/redo.

4. **Events**  
   `EditorEvent` keeps legacy cases and adds:
   - `willApplyEdit(EditTransaction, DocumentSnapshot)`
   - `didApplyEdit(AppliedEditTransaction)`
   - `selectionDidChangeDetailed(SelectionChangeEvent)`  
   Controllers emit **both** legacy and versioned events during the transition.

5. **`EditorLifecycleObserver`**  
   Receives immutable context and transactions without requiring a strong `EditorController` reference. `EditorCoordinator` remains supported.

6. **Stale async work**  
   Highlighter (and completion requests) capture `DocumentVersion` and discard results when the live version differs.

## Consequences

- Providers can reject stale results without holding the view.
- Phase 4 shared documents can reuse the same version/event contracts.
- Snapshots currently copy the full string (acceptable until a COW/rope buffer lands).
