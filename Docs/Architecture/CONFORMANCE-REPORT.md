# Conformance report (Phase 16 RC)

**Status:** residual-closed snapshot  
**Profile:** CodeEditor Swift-first extension platform (`CompatibilityProfile.toml`)

## Levels

| Level | Name | Status | Evidence |
|---|---|---|---|
| **S0** | Package compatibility | passing | s0-basic, TOML corpus, package loader, CLI validate |
| **S1** | Data compatibility | passing | s1-data, contribution loaders, PHASE9 |
| **S2** | Swift API feature parity | passing | ExtensionAPI; Phase 12–13 matrices; slash **stable** |
| **S3** | Behavioral parity | **passing** | Built-in/native Phase 10; Wasm host ABI Stable (ADR-017); dual-run + residual closure tests |
| **S4** | Operational parity | passing | Phase 14 store/signing; Phase 15 profiles |

Levels **S0–S4** describe CodeEditor’s own package/runtime contract. They are not a claim of third-party editor binary compatibility.

## Non-claims (not residuals)

- Full LSP 3.17 beyond [LSP-CLAIMED-MATRIX.md](LSP-CLAIMED-MATRIX.md)
- `language_model_provider_metadata` → **unsupported**
- `legacy_agent_server_hosting` → **unsupported**
- Loading or running unmodified third-party editor extension binaries (e.g. foreign Rust/WIT guest images)

## Runtimes

| Runtime | Status |
|---|---|
| builtin_swift | stable |
| data_only | stable |
| native_process | stable |
| swift_wasm | **stable** (host contract) |
| remote_provider | **stable** |

## Related

- [DEFECTS.md](DEFECTS.md) — zero open
- [ADR-017](ADR-017-core-wasm-abi-v1.md)
- [PHASE16-NOTES](PHASE16-NOTES.md)
