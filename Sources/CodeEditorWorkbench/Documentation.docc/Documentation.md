# ``CodeEditorWorkbench``

Optional SwiftUI workbench shell over Workspace.

## Overview

`CodeEditorWorkbench` is a **SwiftUI shell** that composes workspace, editor,
navigator, utility, and chrome models into an IDE-like surface. It is **not** a
full Xcode replacement.

### Stable 1.0 workbench scope (WB-N07)

Stable 1.0 ships a **bounded** shell:

- Multi-pane editor area (tabs, preview, pin)
- Navigator modes (files, symbols, search, issues, tests, debug, SCM, breakpoints)
- Utility panels (output, problems, terminal) when hosts bind production services
- Open Quickly with background file-tree index
- Command palette, schemes model, activity/progress, multi-window restoration
- Contribution registry with **error presentation** (not crash isolation)
- TaskBag lifecycle scopes; layout-based editor reveal; reduce-motion-aware animation

See ``WorkbenchStableScope/v1`` for the machine-readable included list.

### Explicit gaps vs Xcode (roadmap — not Stable 1.0 claims)

The following remain **out of Stable 1.0 scope** and must not be implied by empty
panels or scaffolding models:

- project/build graph and target model
- Full schemes/configurations/destinations IDE
- Structured build logs / result bundles
- Test plans, coverage navigation
- Diff/merge/conflict editor
- Deep debugger UI (variables, watch, memory, console)
- Preview/canvas providers
- Package dependency navigator
- SCM branches/remotes/auth/conflict resolution UI
- Signing / device / profiling integrations

Empty navigator lists are valid **empty states**, not fake Xcode data.

### Contribution trust (WB-N01)

- **Trusted in-process** Swift contributions may build native views; they are
  **not** security- or crash-isolated.
- **Untrusted** extensions supply **declarative** view models only; the host
  renders them. Error presentation UI is an ordinary failure fallback — not
  fault isolation.

Key guides:

- Product selection: `Docs/Guides/PRODUCT-SELECTION.md`
- API stability: `Docs/Guides/API-STABILITY.md`
- API audit: `Docs/Guides/API-AUDIT.md`

## Topics

- `WorkbenchView` / `WorkbenchModel`
- Contribution slots and declarative untrusted contributions
- `EditorRevealService` layout-based navigation
- `WorkbenchTaskBag` lifecycle
- `WorkbenchWorkflowCoordinator` production service wiring
- `WorkbenchStableScope` Stable 1.0 bounds
- Document view providers
- Open Quickly

## See Also

- Architecture notes under `Docs/Architecture/`
- PHASE notes for the phase that introduced this product
