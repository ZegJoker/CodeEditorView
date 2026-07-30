# ADR-006: Workbench UI shell

## Status

Accepted (Phase 7)

## Context

Phase 6 provides a headless workspace. Hosts need an optional SwiftUI shell for panes, tabs, splits, navigator, status, command palette, and open-quickly—without depending on LSP/search/terminal/SCM products.

## Decision

1. **`CodeEditorWorkbench` product** depends on View, Workspace, Commands, Documents, Core, and LanguageSupport (extension→language mapping only).
2. **`WorkbenchView` + `WorkbenchModel`** compose slot-based chrome driven by `WorkbenchConfiguration`.
3. **`WorkbenchContributionRegistry`** allows hosts to replace/omit navigator, inspector, utility, status, etc.
4. **`DocumentViewRegistry`** selects text / image / PDF providers by file extension; text uses `SharedCodeEditor`.
5. **Command palette** reuses Phase 5 `CommandPaletteView`; active command client comes from `WorkbenchEditorClientRegistry`.
6. **Open Quickly** scans workspace files lazily with result caps.

## Consequences

- Workbench remains buildable without optional IDE products.
- Text editors register lightweight command clients for palette enablement.
- Full EditorController-level commands work when hosts promote shared controllers into the registry later.
