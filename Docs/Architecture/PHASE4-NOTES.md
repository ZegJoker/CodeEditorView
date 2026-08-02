# Phase 4 notes — Workspace & commands transactional

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md` §8–9, Phase 4 gate  
**Branch:** `remediation/audit-2026-08`  
**Policy:** No skip, no defer, no fake implementation, no residuals.

## Goal

Every dirty close routes through a coordinator; workspace edits are journaled and fault-recoverable; paths cannot escape roots; FS ownership is actor-isolated; macOS watch is recursive with overflow; trust defaults restricted; host retains registrations; chords with shared prefixes work; commands return typed results from real context.

## Deliverables

### WSP-001 / WSP-006 — Dirty close + leases

| Item | Status |
|---|---|
| `WorkspaceCloseCoordinator` + fail-closed without delegate | Done |
| `requestCloseTab` / `requestCloseOtherTabs` / `requestCloseTabsToTheRight` / `requestClosePane` / `requestCloseAllTabs` | Done |
| Sync `closeTab` / `closePane` fail closed on last dirty lease | Done |
| `DocumentLeaseRegistry` ref-count; multi-tab close view ≠ dispose doc | Done |
| Workbench UI already uses `requestClose*`; `requestCloseWindow` | Done |

**Evidence:** `Phase4DirtyCloseLeaseTests`, workbench close tests.

### WSP-002 — Workspace edit transactions

| Item | Status |
|---|---|
| Preflight (overlap, version, path, exists) | Done |
| Byte-exact capture + directory archive | Done |
| Durable journal before first destructive FS step | Done |
| Rollback surfaces `.rollbackFailed` / catastrophic (never empty catch) | Done |
| Fault injection: afterFirstDocument, afterDocuments, beforeCommit, afterFirstFileOp | Done |

**Evidence:** `WorkspaceEditTransactionTests`, `Phase4EditFaultTests`.

### WSP-003 — Path security

| Item | Status |
|---|---|
| `RelativeWorkspacePath` typed segments | Done |
| Reject `..`, `.`, NUL, `//`, abs, `\` | Done |
| Component containment + symlink policy + optional same-volume | Done |
| `WorkspacePath.normalize` no longer collapses `..` | Done |

**Evidence:** `Phase4PathSecurityTests`, `pathEscapeRejected`.

### WSP-004 / WSP-005 — FS actor + watcher

| Item | Status |
|---|---|
| `LocalWorkspaceFileSystem` is `actor` (no `@unchecked Sendable`) | Done |
| Protocol API async for roots/item/uri/events | Done |
| FSEvents recursive backend (macOS) with overflow flags | Done |
| `MockWorkspaceFileWatcher` for deterministic overflow tests | Done |
| Cancellation checks on IO paths | Done |

**Evidence:** `LocalFSTests`, `Phase4WatcherTests`.

### Trust §8.7

| Item | Status |
|---|---|
| Default `.restricted` | Done |
| `WorkspaceTrustCapability` gates (task/PTY/ext/LSP/Git/DAP/MCP) | Done |

**Evidence:** `Phase4TrustTests`.

### WSP-007 — Restoration

| Item | Status |
|---|---|
| Reject unknown future schema (workspace + workbench) | Done |
| Corrupt JSON → `corruptPayload` | Done |
| v1 round-trip fixture | Done |

**Evidence:** `Phase4RestorationTests`, workbench future-schema test.

### CMD-001 — RegistrationBag

| Item | Status |
|---|---|
| Explicit `RegistrationBag` owned by `WorkbenchModel` | Done |
| Host builder retains contributions; tearDown disposes bag | Done |

**Evidence:** `registrationBagSurvivesBuild`, `tearDownDisposesBuiltins`.

### CMD-002 — Chord state machine

| Item | Status |
|---|---|
| Exact+prefix → pending (not execute) | Done |
| Longer chord completes; Escape cancels | Done |
| Timeout executes short binding (`resolvePendingChordTimeout` + idle task) | Done |
| Layer precedence (user > built-in) | Done |

**Evidence:** `Phase4ChordTests`, existing `chordResolves`.

### CMD-003 / CMD-004 — Context + typed results

| Item | Status |
|---|---|
| `CommandContextSnapshot` fail-closed defaults | Done |
| Workbench builds snapshot from focus/document/trust | Done |
| `SessionCommandClient` no longer always-true focus/editable | Done |
| `execute` / `executeAsync` → notFound / disabled (no silent success) | Done |

**Evidence:** `Phase4CommandResultTests`, workbench context snapshot test.

## TDD residual pass (post-commit honesty)

Re-opened partial residuals and closed via red→green:

| Residual | Red test | Green fix |
|---|---|---|
| UI Close Pane sync | `workbenchEditorAreaUsesRequestClosePane` | `requestClosePane` on model + WorkbenchEditorArea |
| Mid-rollback silent | `duringRollbackSurfacesTypedFailure` | `WorkspaceEditFaultPoint.duringRollback` |
| FS stress | `concurrentCreateListDeleteConsistent`, `cancelChildrenDoesNotCorruptRoots` | actor already correct; tests prove |
| Golden fixtures | `goldenV1MinimalMigrates` / v999 / corrupt | `Tests/CodeEditorWorkspaceTests/Fixtures/*` |
| Palette typed | `palettePathExecuteUnknownIsNotFound`, `unsupportedResultIsTyped` | already typed; tests prove |

## Gate evidence

```text
swift test --filter 'Phase4'
# 43 tests / 11 suites — all passed
```

Grep bans (manual):

- No `closePane(` / `closeTab(` in `Sources/CodeEditorWorkbench` (user paths use `requestClose*`)
- `LocalWorkspaceFileSystem` is `actor` (not `@unchecked Sendable`)
- `WorkspaceEdit` rollback does not swallow errors

## Defects closed

WSP-001 … WSP-007, CMD-001 … CMD-004 → **fixed**

## Related

- Phase 2 document substrate (CAS save used by dirty save-close)
- Phase 3 native input (command clients)
- Phase 5 Ghostty terminal (out of scope)
- Phase 6 real LSP matrix (out of scope)
