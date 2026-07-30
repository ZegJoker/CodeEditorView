# Migration guide — modular 1.0

This guide helps hosts move from the pre-modular / early-tranche `CodeEditorView` package to the full product graph.

## Tranche 1 — languages

| Before | After |
|---|---|
| Single fat language dependency | `CodeEditorLanguageSupport` + pack products |
| Implicit all-grammar link from View | View **must not** depend on `CodeEditorLanguages` |

Details: [TRANCHE1-MIGRATION.md](../Architecture/TRANCHE1-MIGRATION.md).

```swift
// Launch once:
CodeEditorLanguageSwift.register()
// or
CodeEditorLanguages.bootstrap()
```

## Phase 3–4 — documents and versions

| Before | After |
|---|---|
| Buffer owned only by the view controller | `TextDocument` + `DocumentVersion` / snapshots |
| Attribute-only paints advanced “version” | Content mutations only advance version |

Use `document.snapshot()` for async providers. See ADR-002, ADR-003.

## Phase 5 — commands

| Before | After |
|---|---|
| Hard-wired key handling in platform views | `CommandRegistry` + `KeybindingRegistry` |
| — | Palette via `CommandPaletteModel` / View |

Map existing actions to `CommandID`s (`codeeditor.edit.*`). ADR-004, PHASE5-NOTES.

## Phase 6–7 — workspace and workbench

| Before | After |
|---|---|
| Single open string | `Workspace` multi-root, panes, tabs |
| Custom window chrome | Optional `WorkbenchView` + contributions |

Workbench is **not** required for embedders. ADR-005, ADR-006.

## Phase 8 — language services

| Before | After |
|---|---|
| Only `CodeSuggestionDelegate` / jump delegates | Protocol-neutral `CompletionProvider`, etc. |
| — | `LanguageServiceHost` + View adapters |

```swift
controller.installLanguageServices(host)
// or keep existing delegates
```

ADR-007, PHASE8-NOTES.

## Phase 9–12 — extensions and LSP

| Feature | Product |
|---|---|
| In-process extensions | `CodeEditorExtensions` |
| Out-of-process RPC host | `CodeEditorExtensionHost` |
| Language servers | `CodeEditorLSP` |

Do not import View from extension products. ADR-008, 009, 011.

## Phase 11 — tooling

| Feature | Product | Apply path |
|---|---|---|
| Search/replace in files | `CodeEditorSearch` | `WorkspaceEdit` / `WorkspaceEditService` |
| Tasks | `CodeEditorTasks` | problem matchers → diagnostics sink |
| Terminal | `CodeEditorTerminal` | host maps sessions to UI |
| SCM | `CodeEditorSourceControl` | `GitCLIProvider` optional |

## Checklist

1. Pick a [product profile](PRODUCT-SELECTION.md).  
2. Replace umbrella language link if unnecessary.  
3. Route async language work through snapshots + version checks.  
4. Prefer `WorkspaceEdit` for multi-file mutations.  
5. Read [API stability](API-STABILITY.md) before depending on experimental products.

## Related

- [API audit](API-AUDIT.md)
- Architecture ADRs under `Docs/Architecture/`
