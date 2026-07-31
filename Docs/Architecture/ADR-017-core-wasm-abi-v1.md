# ADR-017: Core-Wasm ABI v1 go/no-go

## Status

**EXPERIMENTAL — ABI v1 NOT FROZEN** (Phase 11 feasibility complete with measured evidence).

## Context

Phase 11 must prove Swift-Wasm extension execution behind `CodeEditorWasmEngine` with the §9.5 core-Wasm message ABI, cooperative `poll`, limits, and malicious containment. The plan forbids freezing the ABI if cancellation, async scheduling, or reproducibility remain unresolved.

## Decision

| Criterion | Evidence | Verdict |
|---|---|---|
| Engine abstraction + WasmKit package linked | `CodeEditorWasmEngine`, `CodeEditorWasmEngineWasmKit` (WasmKit SPM) | PASS |
| ABI exports/imports implemented | `WasmGuestRuntime` + `CoreWasmABISession` + `LinkedGuestWasmEngine` | PASS |
| Cooperative poll scheduling | multi-step work completes across poll budgets (Phase11PollProofTests) | PASS |
| Cancellation path | cancel flag + poll abort (Phase11 cancellation test) | PASS (host-driven) |
| Malicious containment | malformed reject; infinite loop tick interrupt | PASS |
| Dual-run method set parity | built-in vs Wasm activate/echo/completion | PASS |
| Swift WASI cross-compile on this agent host | No WASI SDK installed (`swift sdk list` empty) | **BLOCKER for freeze** |
| Deterministic Swift→wasm artifact hash | `scripts/build-wasm-extension.sh` present; fixture is committed marker module until SDK build | **BLOCKER for freeze** |
| WasmKit executes hand-written bytecode end-to-end for full CBOR guest | Linked guest runs ABI in-process; WasmKit validates/links package; full interpreter of arbitrary wasm CBOR guest deferred to SDK-built module | **PARTIAL** |

**Go/no-go:** **NO-GO for public ABI freeze** until:

1. CI produces `extension.wasm` via pinned WASI SDK and `check-wasm-fixture.sh` compares SHA, and  
2. At least one conformance guest is **executed as Wasm bytecode** under WasmKit (not only linked Swift guest), and  
3. Cancel/scheduling proofs re-run against that bytecode guest.

Until then ABI v1 remains **experimental** (`CoreWasmABI.version = 1` for negotiation) and must not be advertised as Stable.

## Consequences

- Host products ship engine + driver + limits + malicious suite now.
- Runtime selector can choose `.swiftWasm` with real linked-guest execution.
- Authors must not depend on frozen Wasm export layout beyond experimental docs.
- Phase 12+ may consume experimental ABI; freeze is a follow-up gate when WASI CI is green.

## References

- Plan §9.5 Core-Wasm ABI v1  
- `Docs/Architecture/PHASE11-NOTES.md`  
- `Docs/Architecture/WASI-SDK.pin`  
