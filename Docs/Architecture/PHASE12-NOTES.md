# Phase 12 notes — Language-server procedural parity

## Goal

Extensions describe **how** to provision language servers; the host owns process + LSP JSON-RPC. Cover §8.5 hooks end-to-end on every claimed runtime — no defer, no soft-stub.

## Ownership

```
LanguageServerProvider (API)
  → LanguageServerLaunchPlan
      → LanguageServerCoordinator (Host)
          → LanguageServerResolveContextBuilder (worktree which/env/settings/project)
          → LanguageServerLaunchPlanExecutor
              → CapabilityBroker (download/npm/process/worktree)
              → LanguageServerPool / Session (LSP)
              → LSPClientProviders + completion/symbol label hooks
              → LanguageServiceRegistry
          → LanguageServerStatusStore
```

## Author API

| Type | Module |
|---|---|
| `LanguageServerLaunchPlan` / `LanguageServerBinarySource` | API |
| `LanguageServerProvider` | API |
| `LanguageServerResolveContext` (+ which/env/settings/project) | API |
| `LanguageServerLanguageMap` | API |
| `LanguageServerStatus` / diagnostics codes | API |
| `ExtensionPlatformInfo` | API |
| `[language_servers.*]` TOML | API loader |

### Provider hooks (§8.5)

| Hook | Surface |
|---|---|
| Select bundled/system/downloaded/npm/absolute/test | `LanguageServerBinarySource` |
| Platform / arch | `ExtensionPlatformInfo` / resolve context |
| Find executables in scoped worktree | `broker.worktree.which` + `context.whichResults` |
| Allowed worktree environment | `broker.worktree.environment` + `context.environmentValues` |
| Project/worktree metadata | `context.projectMetadata` |
| Query settings | `context.settingsValues` / settings handle |
| Download + digest | broker download (HTTPS + fixture digest) |
| npm install | broker npm (no lifecycle scripts) |
| Launch plan fields | `LanguageServerLaunchPlan` |
| initializationOptions | provider + session |
| workspace/configuration | session handler |
| Per-language server mappings | `LanguageServerLanguageMap` |
| Completion / symbol label transforms | hooks + LSP adapters |
| Status | `LanguageServerStatusStore` |
| Restart / settings invalidation | coordinator + pool / re-resolve |

## TOML

```toml
[language_servers.mock-ls]
name = "Mock LS"
languages = ["Swift"]
command = "mock-ls"
```

Parity profile becomes `codeeditor-ls-s2` when language servers are present.

## Host components

| Component | Role |
|---|---|
| `LanguageServerLaunchPlanExecutor` | validate → materialize → start pool → hooks → status |
| `LanguageServerCoordinator` | providers, language map, start/stop, settings invalidation, wire dispatch |
| `LanguageServerResolveContextBuilder` | mint handles + populate which/env/settings/project |
| `LanguageServerWireCodec` | `ls.*` JSON encode/decode + provider dispatch |
| `LanguageServerLabelHookRegistry` | completion + symbol transforms |
| `LanguageServerStatusStore` | lifecycle + diagnostics stream |

## Process materialization

`ensureProcessAllowed` requires:

1. `startProcesses` capability grant
2. Executable on broker process allowlist (not a soft check)

Download fixtures enforce optional SHA-256 digest mismatch as hard failure.

## Label hooks

`LSPClientProviders.register(..., completionLabelHook:, symbolLabelHook:)` applies transforms after LSP decode for completions, document symbols, and workspace symbols.

## Wire catalog (native / Wasm / built-in)

```
ls.resolveLaunchPlan
ls.initializationOptions
ls.workspaceConfiguration
ls.transformCompletionLabel
ls.transformSymbolLabel
ls.status
ls.restart
broker.worktree.which
broker.worktree.environment
```

Schema hash recomputed in `ExtensionMethodCatalog`.

Built-in instances attach an optional `LanguageServerProvider` and dispatch `ls.*`.
Native guest runtime attaches a provider via `setLanguageServerProvider`.
Wasm linked-guest returns Codable plan shapes + label transforms.

## Runtimes

| Runtime | Coverage |
|---|---|
| Built-in | Provider + executor + mock LS E2E + `ls.*` instance dispatch |
| Native-process | Guest `ls.*` dispatch + plan materialization + process grants |
| Swift-Wasm | Catalog methods + Codable plan shape + label/status (linked-guest experimental) |

## S2 matrix

| Procedural hook | API | Test |
|---|---|---|
| Select bundled/system/downloaded/npm | `LanguageServerBinarySource` | TOML seeds + materialize tests |
| Platform/arch | `ExtensionPlatformInfo.current` | resolve context |
| Worktree PATH / relative binary | which + path escape deny | worktree + validation tests |
| Allowed env vars | worktree.environment | allowlist filter test |
| Settings | resolve context settingsValues | context builder |
| Download + digest | broker download | deny without grant + digest mismatch |
| npm install | broker npm | materialize path |
| Launch plan fields | `LanguageServerLaunchPlan` | E2E |
| initializationOptions | provider + session | E2E |
| workspace/configuration | session handler | E2E |
| Language mappings | `LanguageServerLanguageMap` | unit + coordinator |
| Label transforms | hooks + adapters | E2E + unit |
| Status | `LanguageServerStatusStore` | E2E |
| Restart / settings change | coordinator.invalidate | coordinator test |
| Process allowlist | `processAllowed` | deny unlisted binary |

## Gate evidence

```bash
swift test --filter Phase12
swift test --filter LanguageServerTOML
./scripts/check-product-isolation.sh
./scripts/check-docs.sh
```

ExtensionHost may import `CodeEditorLSP` for plan execution (isolation script updated).

## Fixture

`Tests/Fixtures/Extensions/ls-procedural/extension.toml`
