# ADR-008: In-process extension runtime

## Status

Accepted (Phase 9)

## Context

Phases 1–8 modularized core, documents, commands, workspace, workbench, and language services. Extensions need a portable way to contribute commands, languages, language-service providers, panels, themes, and snippets without requiring ExtensionKit or a full IDE host.

Out-of-process macOS hosting (ExtensionKit/XPC) is deferred to Phase 12.

## Decision

1. **`CodeEditorExtensions` product** depends on Core, Documents, Commands, LanguageSupport, and LanguageServices. It must not depend on View, Workbench, Workspace, TreeSitter, grammars, LSP, or ExtensionKit.

2. **Three contribution modes (framework §11):**
   - Compile-time Swift types implementing `CodeEditorExtension` (primary).
   - Data-only JSON bundles (`DataExtensionLoader`) for themes, snippets, keybindings, language metadata.
   - Out-of-process ExtensionKit host (Phase 12 only).

3. **`ExtensionRuntime` actor** owns registration, activation events, compatibility gates (API version + host capabilities), permission intersection, activate/deactivate, status, and logging.

4. **Host injects services** via `ExtensionHostServices` (command/keybinding registries, language registry, language-service registry, panel/theme/snippet stores, storage root). Feature modules do not import Extensions.

5. **Typed registrars** wrap existing registries and return disposal tokens tracked by `ExtensionContext`. Deactivation cancels tasks and disposes tokens (LIFO).

6. **Panels are UI-free descriptors** (`PanelContribution`). Workbench maps them to `WorkbenchContribution` at the host edge so Extensions stays free of SwiftUI.

7. **Permissions are enforced by clients** (`requirePermission`, panel registrar, storage path sandbox), not merely declared on the manifest. Hosts grant the intersection of requested ∩ allowed permissions.

8. **`LanguageRegistry` gains unregister APIs** so language-meta contributions can be removed on deactivate.

## Consequences

- A small host can advertise a subset of `HostCapability` and refuse incompatible extensions.
- Phase 10 LSP can register providers directly or via an extension.
- Phase 12 reuses manifests/permissions and adds remote registrar adapters without changing the in-process contract.
- Extension manager UI remains out of scope for Phase 9 (status/log model only).
