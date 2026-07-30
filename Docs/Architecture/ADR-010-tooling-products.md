# ADR-010: Search, tasks, terminal, and source control products

## Status

Accepted (Phase 11)

## Context

Phases 1–10 delivered modular core, workspace, workbench, language services, extensions, and LSP. Hosts still need independently optional tooling: workspace search/replace, tasks/output, terminal, and source control—without forcing a full IDE dependency graph.

## Decision

1. **Four separate products:** `CodeEditorSearch`, `CodeEditorTasks`, `CodeEditorTerminal`, `CodeEditorSourceControl`. No mutual dependencies.

2. **Search** is multiplatform streaming scan (not SearchKit). Open documents are searched from memory; replace builds `WorkspaceEdit` for `WorkspaceEditService`.

3. **Tasks** use a pluggable `TaskRunner` (`ProcessTaskRunner` default), output channels, dependency topo-sort, and problem matchers that publish `LanguageDiagnostic` via a host `TaskDiagnosticsSink`.

4. **Terminal** is headless: `TerminalBackend` + session manager. Process pipes are provided; full PTY/SwiftTerm is optional later. Hosts map `TerminalPanelDescriptor` into workbench UI.

5. **Source control** starts with a provider protocol and a `GitCLIProvider` (porcelain parsing + CLI). No libgit2 requirement.

6. **Isolation:** none of these products import View, Workbench, LSP, Extensions, or TreeSitter.

## Consequences

- Apps link only the tooling they need.
- Replace/rename/code actions continue to share workspace edit semantics.
- Workbench chrome remains optional and host-composed.
