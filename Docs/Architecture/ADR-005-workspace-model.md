# ADR-005: Headless workspace model

## Status

Accepted (Phase 6)

## Context

Phases 3–5 provide versioned documents, sessions, and commands. Hosts still need a multi-root project model: lazy file trees, panes/tabs/splits, navigation history, state restoration, and a transactional workspace edit service—without SwiftUI.

## Decision

1. **`CodeEditorWorkspace` product** — depends on Core + Documents only.
2. **`WorkspaceFileSystem`** + **`LocalWorkspaceFileSystem`** — lazy `children`, CRUD, multi-root, event stream.
3. **`WorkspaceFileTree`** — expanded-node cache; never loads entire trees eagerly.
4. **`EditorPane` / `EditorTab`** — preview tab policy (one unpinned preview; pin/edit promotes).
5. **`EditorLayoutStore`** — recursive pane/split tree with normalization.
6. **`Workspace`** — orchestrates documents registry, open/close, focus/nav history.
7. **`WorkspaceRestorationState`** — schema version 1 JSON encode/restore with migrate hook.
8. **`WorkspaceEditService`** — validates versions, applies open-document transactions, file ops via FS, rename re-URIs open docs.

## Consequences

- Phase 7 workbench can bind UI to this model without embedding FS logic.
- File watching is intentionally minimal (explicit ops + event stream); hosts may add richer watchers later.
- Workspace stays free of Commands/View to preserve headless use and isolation.
