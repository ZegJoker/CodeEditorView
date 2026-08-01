# Phase 13 notes — DAP, MCP, slash commands, and documentation

## Goal

Ship debugger/MCP/command/docs extension surfaces with real host ownership of protocol sockets. Label compatibility honestly.

## Products

| Product | Role |
|---|---|
| **CodeEditorDAP** | DAP client, session, pool, mock adapter |
| CodeEditorTasks | Pre/post debug tasks |
| CodeEditorTerminal | `runInTerminal` reverse-request injection |
| CodeEditorExtensionAPI | Author types + TOML contributions |
| CodeEditorExtensionHost | Launch plan executors, MCP client, slash/docs services |

## Ownership

```
DebugAdapterProvider → DebugAdapterLaunchPlan
  → DebugAdapterLaunchPlanExecutor → CapabilityBroker → DebugAdapterPool (DAP)

MCPServerProvider → MCPServerLaunchPlan
  → MCPServerPool / MCPClientSession (host-owned JSON-RPC)

SlashCommandProvider → SlashCommandService (sanitize + stream + cancel)
DocumentationIndexProvider → DocumentationIndexService (quota store)
```

## Compatibility labels (§6.3)

| Feature | Label |
|---|---|
| `debug_adapters` / `debug_locators` / `mcp_servers` / `documentation_indexing` | **stable** |
| `slash_commands` | **compatibility** |
| `language_model_provider_metadata` | experimental |
| `legacy_agent_server_hosting` | unsupported |

Loader: `CompatibilityProfileLoader` + `Docs/Architecture/CompatibilityProfile.toml`.

## DAP matrix (fixture)

Mock adapter covers initialize, launch/attach, breakpoints (source/function/exception/instruction/data), threads/stack/scopes/variables/evaluate, step controls, modules/sources/memory/disassemble/completions, reverse `runInTerminal`.

## MCP matrix (fixture)

Mock peer: `initialize`, `tools/list`, `tools/call`, `resources/list`, `prompts/list`.

## TOML

```toml
[debug_adapters.mock-dap]
languages = ["Swift"]
command = "mock-dap"

[mcp_servers.mock-mcp]
command = "mock-mcp"
transport = "stdio"

[slash_commands.explain]
name = "explain"
description = "Explain selection"

[documentation_packages.swift-std]
languages = ["Swift"]
source_path = "docs/swift.md"
```

## Gate

```bash
swift test --filter CodeEditorDAP
swift test --filter Phase13
swift test --filter CompatibilityProfile
./scripts/check-product-isolation.sh
./scripts/check-docs.sh
```

## Soft-stub ban (enforced)

| Forbidden | Actual behavior |
|---|---|
| Canned `{"ok":true}` / `[]` for `dap.*` / `mcp.*` / `slash.*` / `docs.*` | `methodNotFound` unless providers/services are attached |
| Invented npm bin scripts | `binaryNotFound` if install does not produce the bin |
| Docs index with synthetic filler entries | Requires real worktree file **or** provider-emitted entries |
| Wasm Phase 13 success without handlers | Error JSON `-32601` until `setHandler` registers real logic |
| `runInTerminal` no-op | Must go through `TerminalSessionManager` / injected handler |

Wire path: `Phase13WireCodec` + provider attach on BuiltIn/Guest; host-owned status/restart via executors.
