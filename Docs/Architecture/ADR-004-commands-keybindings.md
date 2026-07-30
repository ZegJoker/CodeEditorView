# ADR-004: Commands and keybindings

## Status

Accepted (Phase 5)

## Context

Editing actions were hard-wired in platform views (`AppKitEditorView.keyDown`, `UIKitEditorView.keyCommands`) and only callable as `EditorController` methods. Hosts and future extensions need namespaced command IDs, layered keybinding overrides, enablement expressions, and a command palette model without depending on view types.

## Decision

1. **`CodeEditorCommands` product** — platform-neutral registries, dispatcher, keybinding model, context expressions, palette model.
2. **`CommandID` / `EditorCommand`** — namespaced IDs (`codeeditor.*` built-ins); MainActor handlers for editor mutations.
3. **`CommandContext` + `EditorCommandClient`** — restricted clients; no `EditorController` in the Commands module.
4. **`ContextExpression`** — serializable tree for enablement/when (not free-form strings).
5. **Keybinding layers** — builtIn < extension < host < workspace < user; then priority; then stable CommandID.
6. **`CommandDispatcher`** — execute by ID; chord-aware `handleKeyPress`.
7. **Built-ins** — installed on every `EditorController` via `installBuiltInCommands`; platform views route shortcuts through the dispatcher.
8. **Palette** — `CommandPaletteModel` + optional `CommandPaletteView`.

## Consequences

- Existing controller methods remain the implementation; commands call them through `EditorCommandAction`.
- Hosts can register additional commands and dispose them without leaks.
- Workspace/pane context fields remain optional until Phase 6.
