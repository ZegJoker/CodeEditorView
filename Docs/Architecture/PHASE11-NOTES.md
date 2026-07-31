# Phase 11 notes — Swift-Wasm feasibility and core-Wasm ABI

## Goal

Prove Swift-Wasm extension execution: engine protocol + WasmKit product, core-Wasm ABI v1, cooperative poll, limits, malicious containment, dual-run traces. **Do not freeze ABI without full WASI bytecode proof** (see ADR-017).

## Products

| Product | Role |
|---|---|
| `CodeEditorWasmEngine` | Portable engine protocol, limits, meters, module builder, linked/in-process engines |
| `CodeEditorWasmEngineWasmKit` | WasmKit SPM-linked reference backend |
| `CodeEditorExtensionWasmGuest` | Cooperative guest implementing ABI export semantics + CBOR |
| `CodeEditorExtensionHost` | `CoreWasmABISession`, `SwiftWasmRuntimeDriver`, selector |

## Core-Wasm ABI v1 (§9.5)

Exports: `codeeditor_abi_version`, `alloc`, `dealloc`, `start`, `receive`, `poll`, `stop`  
Imports: `codeeditor_host_send`, `host_log`, `host_monotonic_millis`, `host_should_cancel`  

Semantic payloads = Phase 10 CBOR envelopes (same schema hash).

## Limits

`WasmResourceLimits`: max module/memory, wall time, poll budget/ticks, host_send queue, log bytes.

## Fixtures

`Tests/Fixtures/Wasm/` — malformed, missing export, conformance marker, infinite loop, etc.  
`scripts/build-wasm-extension.sh` — cross-compile when pinned WASI SDK installed.  
`scripts/check-wasm-fixture.sh` — fixture presence (+ optional rebuild).

## ADR-017 verdict

**EXPERIMENTAL / NO-GO for freeze** until CI builds real `extension.wasm` via WASI SDK and WasmKit executes that bytecode guest end-to-end. Linked-guest dual-run + containment tests **pass** now.

## Gate evidence

```bash
swift test --filter 'Phase11|WasmEngine'
# 12 tests passed
./scripts/check-product-isolation.sh
./scripts/check-wasm-fixture.sh
```

| Suite | Result |
|---|---|
| Engine limits/malformed/missing export/loop interrupt | PASS |
| ABI echo/activate/completion | PASS |
| Dual-run method set built-in vs Wasm | PASS |
| Cooperative multi-step poll | PASS |
| Host_send backpressure | PASS |

## Isolation

Author API / Protocol / Guest (stdio) do **not** import WasmKit. Only `CodeEditorWasmEngineWasmKit` + Host may.
