# Phase 6 notes — Language services and complete LSP host

## Goal

Stable multi-provider arbitration for every LanguageServices category; full bidirectional JSON-RPC LSP host with capability-gated adapters; unavailable behavior explicit.

Pinned protocol: **LSP 3.17** (`LSPProtocolVersion`).

## Ownership model

```
LanguageServiceRegistry (health + matching)
  └─ LanguageServiceHost (timeout / cancel / stale / isolate / limits / merge)
       ├─ built-in / mock providers
       ├─ host-app providers
       └─ LSPClientProviders → LanguageServerSession
              ├─ LSPJSONRPCConnection (bi-directional RPC)
              ├─ LSPPositionMapCache
              └─ LSPProcessTransport (process group kill)
```

## LanguageServices deliverables

| Item | Status |
|---|---|
| Shared `run`/invoke policy: timeout, cancel, stale-revision, failure isolation | Done |
| `LanguageServiceLimits` + result sanitization / caps | Done |
| Provider health snapshots on registry | Done |
| New categories: highlights, type/call hierarchy, execute command, pull diagnostics | Done |
| Host methods for every registered category | Done |
| Multi-provider matrix + isolation tests | Done (`PolicyEngineTests`) |

## LSP deliverables

| Item | Status |
|---|---|
| Typed models + `LSPProtocolVersion` 3.17 | Done |
| Bidirectional JSON-RPC: cancel, server→client requests, progress | Done |
| Framing caps + fuzz (split, invalid length, huge body/buffer) | Done |
| Full client initialize capabilities | Done |
| Dynamic registration / applyEdit / showMessageRequest / configuration / workspaceFolders | Done |
| Position map cache (versioned line index) | Done |
| Process group kill + stderr caps | Done |
| Restart with backoff + document resync | Done |
| Adapters for all advertised capabilities (never silent unsupported) | Done |
| Scripted mock matrix covering all methods | Done |

## Capability / adapter matrix (evidence)

| LanguageServices category | Host arbitration | LSP adapter | Explicit unavailable |
|---|---|---|---|
| completion | merge + limits | `textDocument/completion` | not registered without cap |
| hover | merge sections | `textDocument/hover` | same |
| definition / declaration / implementation / references | merge locations | matching methods | same |
| diagnostics (push) | merge + ownership | stream + empty pull-through | — |
| pull diagnostics | merge | `textDocument/diagnostic` | `LSPError.capabilityUnavailable` |
| document / workspace symbols | merge | matching methods | same |
| formatting / range formatting | highest priority | matching; range requires cap | capability guard |
| rename | highest priority | `textDocument/rename` | same |
| code actions | merge | `textDocument/codeAction` | same |
| semantic tokens full/range | merge | full + range when cap | same |
| signature help | first non-nil | matching | same |
| inlay hints | merge | matching | same |
| folding | first non-empty | matching | same |
| document links / colors | merge | matching | same |
| document highlights | merge | matching | same |
| type / call hierarchy | merge prepare | matching | same |
| execute command | first match | `workspace/executeCommand` | `noProvider` / empty commands |

## Gate evidence

| Check | Result |
|---|---|
| `swift test --filter CodeEditorLanguageServices` | **23 tests / 4 suites — passed** |
| `swift test --filter CodeEditorLSP` | **24 tests / 7 suites — passed** |
| View host category + revision guard | `LanguageServicesAdapterTests.hostCategoryMatrixWithRevisionGuard` |
| CI job `lsp-matrix` | mock suites required; real `sourcekit-lsp` / `clangd` probed when present |
| Platform process unavailable | still fail-closed (`LSPPlatformTests`) |

### Position map large-document note

`LSPPositionMap` builds O(n) line starts once per version; conversion is O(log lines). Benchmark: multi-megabyte documents should use the cache via open/change path rather than linear scan per request.

### Real servers

| Server | CI behavior |
|---|---|
| MockLanguageServer (scripted) | **Required** full method matrix |
| `sourcekit-lsp` | Run when installed; otherwise skip with explicit summary note |
| `clangd` | Same secondary probe |

## Residual / follow-ups

- Nightly job that **requires** sourcekit-lsp on a toolchain image
- Partial-result token streaming end-to-end against a real server
- Completion/codeAction/inlay **resolve** round-trips
- Semantic tokens delta apply path
- iOS: process LSP remains profile-gated; mock/in-process adapters usable

## Related

- Phase 5: View façade / IME / theme
- Phase 7: Tasks, Terminal, SourceControl
- ADR-007 language services, ADR-009 LSP client
