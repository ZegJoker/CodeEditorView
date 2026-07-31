# ADR-016: Platform capability profiles

## Status

Accepted (Phase 0)

## Context

The package advertises iOS 18+ and macOS 15+. Several products use `Foundation.Process` (LSP, Tasks, Terminal, SourceControl, ExtensionHost). Compiling for iOS is not the same as supporting local process tooling. Hosts need explicit capability profiles so APIs fail closed with typed errors rather than incidental Foundation failures.

## Decision

### Feature availability kinds

Each feature reports one of:

- `.local` — available on-device / on-host
- `.remote` — available via remote provider
- `.hostProvided` — application injects implementation
- `.dataOnly` — declarative resources only
- `.unavailable(reason:)` — not offered; operations throw before work begins

Unsupported operations return `CodeEditorPlatformError.unsupportedCapability` (introduced Phase 1) before starting work.

### Shipping profiles

| Profile | Runtimes / local tools |
|---|---|
| **A — Direct-distribution macOS** | Built-in, data-only, Swift-Wasm, trusted native process; local LSP/DAP/MCP/tasks/terminal/Git; registry and dev install |
| **B — Mac App Store** | Built-in, data-only, bundled Wasm, remote providers; local tools only under sandbox/entitlements; no silent downloadable native helpers |
| **C — iOS/iPadOS App Store** | Built-in + data-only (+ bundled Wasm where useful); remote tooling; **no** downloadable native code, arbitrary local processes, local PTY terminal, or Git CLI as default stable promise |
| **D — Enterprise/internal** | May enable signed org helpers, managed registries, MDM; still requires audit/sandbox discipline |
| **E — Tests/embedded** | Deterministic in-process/mock drivers; no marketplace/network required |

### Product implications

- Process-backed products may **compile** for iOS but must expose `.unavailable` or `.remote` for local process launch unless a host-provided backend exists.
- Extension host selection policy prefers data-only / built-in / remote on iOS; never implies downloadable executable extensions.
- Documentation and manager UI explain why an artifact cannot run and whether a remote fallback exists.

### Implementation timing

- Types and fail-closed guards: **Phase 1**
- Per-product adoption: phases that touch each product
- Feature-flagged shipping binaries: **Phase 15**

## Consequences

- Consumers query profile before offering UI for Git/terminal/native extensions.
- CI must include iOS builds that assert unsupported local process paths do not pretend success.
- App Review and legal evaluation remain separate from technical feasibility for downloadable code.
