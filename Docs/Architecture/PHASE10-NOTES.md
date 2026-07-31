# Phase 10 notes — Native Swift process runtime

## Goal

Run the same Swift extension **in-process** and as a **native helper** over a versioned **CBOR** wire protocol, with process-group teardown, restart/quarantine, capability broker, and signed/dev package trust.

## Products

| Product | Role |
|---|---|
| `CodeEditorExtensionProtocol` | CBOR codec, 4-byte framing, method catalog + schema hash, wire connection |
| `CodeEditorExtensionGuest` | Guest runtime + stdio transport for Swift executables |
| `ConformanceExtensionGuest` | Fixture executable for dual-run |
| `CodeEditorExtensionHost` | Drivers, orchestrator, broker, signing, native transport |

## Wire protocol

- Canonical framing: **big-endian u32 length + CBOR body**
- Schema source: `ExtensionMethodCatalog.entries` → `schemaHash` (SHA-256)
- Handshake carries protocol version, schema hash, package id/version/digest, capabilities, grants, limits, generation
- JSON remains **diagnostic only** (`JSONDiagnosticRenderer`); legacy Content-Length JSON RPC still exists for older remote adapters

## Runtime drivers

```text
RuntimeSelector → BuiltInSwiftRuntimeDriver
                → NativeProcessRuntimeDriver
                → swiftWasm (reserved; throws not available)
```

Shared `ExtensionInstance` surface: request/cancel/stop + conformance traces.

## Capability broker

Fail-closed handles for:

- worktree (path containment)
- project
- settings
- storage (quota)
- process (allowlist + process-group kill via `ProcessService`)
- download (HTTPS host allowlist; fixture path for tests)
- npm (allowlist, no lifecycle scripts)

Forged / stale generation handles reject.

## Trust

- Ed25519 sign/verify over `checksums.json` + `signature.ed25519` + `publisher.json`
- Classes: `trustedSigned` / `workspaceDev` / `untrusted`
- Native launch denied for untrusted under strict policy
- Notice: native helper is a **reliability** boundary, not a sandbox (`NativeProcessTrustNotice`)

## Guest executable

```bash
swift build --product ConformanceExtensionGuest
# Host spawns Artifacts/.../extension or .build/.../ConformanceExtensionGuest
```

## Gate evidence

| Check | Result |
|---|---|
| Protocol CBOR/framing/catalog tests | Pass |
| Dual-run built-in trace + native mock guest handshake/activate/echo/completion | Pass |
| Broker worktree/process/download/npm/storage/forged handles | Pass |
| Sign/verify + untrusted reject | Pass |
| Process group terminate (sleep helper) | Pass |
| Quarantine after crash storm | Pass |

```bash
swift test --filter CodeEditorExtensionProtocolTests
swift test --filter 'Phase10DualRun|Phase10Broker|Phase10Signing|Phase10Orchestrator|Phase10Process'
scripts/check-product-isolation.sh
```

## Explicitly not Phase 10

- WasmKit / core-Wasm ABI (Phase 11)
- Full LS procedural provisioning (Phase 12)
- Marketplace COSE gallery (later)
