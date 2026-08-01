# ADR-017: Core-Wasm ABI v1 go/no-go

## Status

**Accepted — ABI v1 Stable for host execution contract** (Phase 16 residual closure).

Author-side Swift→WASI cross-compile remains a **toolchain pin** (`WASI-SDK.pin` + `scripts/build-wasm-extension.sh`), not an open product residual.

## Context

Phase 11 proved Swift-Wasm extension execution behind `CodeEditorWasmEngine` with the §9.5 core-Wasm message ABI, cooperative `poll`, limits, and malicious containment. Phase 16 residual closure promotes the **host runtime contract** to Stable based on that evidence.

## Decision

| Criterion | Evidence | Verdict |
|---|---|---|
| Engine abstraction + WasmKit package linked | `CodeEditorWasmEngine`, `CodeEditorWasmEngineWasmKit` | PASS |
| ABI exports/imports implemented | `WasmGuestRuntime` + `CoreWasmABISession` + linked guest | PASS |
| Cooperative poll scheduling | Phase11 poll proof tests | PASS |
| Cancellation path | Phase11 cancel tests | PASS |
| Malicious containment | malformed / infinite loop / missing export fixtures | PASS |
| Dual-run method set parity | built-in vs Wasm activate/echo/completion | PASS |
| Fixture bytecode under engine | `Tests/Fixtures/Wasm/*` + `check-wasm-fixture.sh` + engine validate/instantiate tests | PASS |
| Host ABI freeze | `CoreWasmABI.version = 1` is the stable negotiation version | **STABLE** |

**Go/no-go:** **GO for host ABI v1 Stable**.

Author WASI SDK builds of custom guests are supported when the pinned SDK is installed; CI may use committed fixture modules as the hermetic gate. The stable claim is CodeEditor’s **core-Wasm host ABI and engine limits**, not any third-party guest image format.

## Consequences

- `CompatibilityProfile` runtime `swift_wasm = stable`.
- Runtime selector may choose `.swiftWasm` under shipping profiles that allow bundled/downloadable Wasm.
- Residual defects P16-001 / P16-002 closed.

## References

- Plan §9.5 Core-Wasm ABI v1  
- `Docs/Architecture/PHASE11-NOTES.md`  
- `Docs/Architecture/WASI-SDK.pin`  
- Phase 16 residual closure  
