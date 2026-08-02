# Phase 9 notes — Real Swift-Wasm execution

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md`  
- Phase gate: **§ Phase 9**  
- Findings: **§16.1–16.10**

**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD residual completion; no soft-stubs for isolation claims.

> Prior `PHASE9-NOTES` content described Author API + TOML (pre-audit numbering). That work lives under the extension API / store phases. **Audit Phase 9 is real Wasm execution.**

## Goal

Isolated portable procedural extensions: submitted `.wasm` bytes determine behavior under WasmKit; hostile modules are contained; LinkedGuest remains dual-run semantics only.

## Architecture

```text
Swift extension source
  → pinned WASI SDK (WASI-SDK.pin)
  → .wasm artifact (or WasmModuleBuilder fixtures)
  → package signature (Phase 8)
  → WasmKitEngine (real parse/instantiate/call)
  → CoreWasmABISession (ABI v1)
```

| Product | Role |
|---|---|
| `CodeEditorWasmEngine` | Protocol, limits, meters, module builder, **LinkedGuest simulation** |
| `CodeEditorWasmEngineWasmKit` | Real WasmKit backend |
| `CodeEditorExtensionHost` | `CoreWasmABISession`, `SwiftWasmRuntimeDriver` (default WasmKit) |

## Deliverables

| Item | Status |
|---|---|
| Module bytes determine `abi_version` / behavior (not factory) | Done |
| WasmKit parse rejects malformed/missing magic | Done |
| Host imports read guest linear memory (ptr/len) | Done |
| Wall-time watchdog + cooperative cancel interrupt | Done |
| Memory OOB trap + max linear memory policy | Done |
| Hostile corpus exercised on WasmKit | Done |
| Dual-run LinkedGuest labeled non-isolation | Done |
| `CodeEditorWasmSimulationEngine` = LinkedGuest (not WasmKit) | Done |
| `check-wasm-fixture.sh` + REQUIRE_WASM_FIXTURES | Done |
| PHASE9-NOTES rewritten | Done |

## Gate evidence

```text
swift test --filter 'Phase9|RealWasm'
# Phase9 real WasmKit suite + RealWasmExecutionTests — passed

./scripts/check-wasm-fixture.sh
# lists committed Fixtures/Wasm/*

./scripts/check-defects.sh
```

### Exit map

| # | Proof |
|---|---|
| E1 | `moduleBytesDetermineAbiVersion`, `factoryIgnoredOnlyModuleExportsMatter` |
| E2 | `rejectsMalformedAndMissingMagic` |
| E3 | `freshStorePerInstance` |
| E4 | `hostSendReadsGuestMemory` |
| E5 | `infiniteLoopInterruptedWithoutHang` |
| E6–E7 | `memoryLimitEnforced…`, `oobMemoryReadTraps` |
| E8 | `hostileFixturesOnWasmKit` |
| E9 | `Phase9DualRunContractTests` |
| E10–E11 | `simulationAliasIsNotWasmKit`, factory comments |
| E12 | `scripts/check-wasm-fixture.sh` |
| E13–E14 | session stop in dual-run; this file + defects |

## Forbidden residuals (verified)

- Isolation claims from LinkedGuest magic+`0xAB` fixtures  
- `CodeEditorWasmSimulationEngine` aliasing WasmKit  
- Host imports ignoring guest memory  
- Infinite loop hang without interrupt path  

## Related

- Phase 8 package signing before activation  
- Phase 11 historical dual-run / ABI feasibility notes  
- ADR-017 core-Wasm ABI v1  
- Audit Phase 10 workbench (out of scope)  
