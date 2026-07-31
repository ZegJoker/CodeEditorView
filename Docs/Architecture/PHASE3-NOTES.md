# Phase 3 notes — Commands, Workspace, Search transactions

## Goal

Randomized rollback and stale-revision suites pass; multi-file edits and search-replace cannot partially corrupt a workspace; commands support async execution and when-clause parsing.

## Deliverables

### CodeEditorWorkspace

| Item | Status |
|---|---|
| Transactional `WorkspaceEditService.apply` with journal + reverse rollback | Done |
| Fault injection points for gate tests | Done |
| Stale `expectedVersion` preflight + recheck | Done |
| `WorkspacePathSecurity` root containment / `..` rejection | Done |
| `WorkspaceSnapshot` + `WorkspaceTrustState` | Done |
| Directory `DispatchSource` watchers → `.rescanRequired` | Done |
| Restoration schema forward-compat clamp | Done |
| `DirtyTabClosePolicy` enum | Done |

### CodeEditorSearch

| Item | Status |
|---|---|
| `SearchBackend` + `NativeSearchBackend` | Done |
| Gitignore-style rules + loader | Done |
| Search respects gitignore + binary/size limits | Done |
| `SearchReplaceService` via transactional WorkspaceEdit | Done |
| Stale open-doc replace aborts | Done |

### CodeEditorCommands

| Item | Status |
|---|---|
| `asyncHandler` + `executeAsync` / `CommandResult` | Done |
| `CommandDependencies` typed bag | Done |
| `WhenClauseParser` (&& \|\| ! comparisons, diagnostics) | Done |
| Keybinding conflict inspection API | Done |
| Ranked command palette matching | Done |

## Gate evidence

| Suite | Result |
|---|---|
| Stale version aborts with no mutation | Pass |
| Fault after first document rolls back | Pass |
| Path escape rejected | Pass |
| Search replace with stale open doc | Pass |
| Gitignore hide/show | Pass |
| When-clause language compare | Pass |
| Async command path | Pass |
| Keybinding conflict winner = user over built-in | Pass |

**Local verification:** `swift test` → **407 tests / 114 suites — all passed**.

## Residual

- Full gitignore corner-case corpus (nested `**`, character classes)
- Ripgrep backend (optional; native is complete)
- FSEvents rename pairing (current watcher coalesces to rescan)
- Complete IME/UIKit keyboard matrix (host-level)
- Dispatcher reentrancy lock under concurrent `executeAsync` storms

## Related

- Phase 2 DocumentIO used by file ops where applicable  
- Phase 4: language packs / Tree-sitter reproducibility  
