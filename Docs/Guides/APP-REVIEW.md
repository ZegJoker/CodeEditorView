# App Review and shipping profile claims

This document describes **what CodeEditorView library profiles claim** for Apple App Review–relevant packaging. It is not a substitute for legal counsel. Host applications choose a `ShippingProfileID` and must not claim capabilities their binary gates deny.

## Shipping profiles (A–E)

| ID | Intended binary | Local process / PTY / Git | Native helpers | Bundled Wasm | Marketplace Wasm | Dynamic install | Remote tooling |
|---|---|---|---|---|---|---|---|
| `direct-macos` | Direct-distribution macOS | Yes | Trusted / workspace-dev (policy) | Yes | Yes (trust-gated) | Full | Yes |
| `mac-app-store` | Mac App Store | Process/Git local; PTY opt-in | **No** (default) | Yes | **No** | Data-only | Yes |
| `ios` | iOS/iPadOS App Store | **No** local process/PTY/Git; LS **remote** | **No** | Yes | **No** | Data-only | Yes |
| `enterprise` | Internal / MDM-managed macOS | Yes | Org-signed (required) | Yes | Policy | Managed registry | Yes |
| `test` | CI / embedded hosts | Yes (deterministic) | Yes (test trust) | Yes | Yes | Full | Yes |

Machine-readable matrix: `Tests/Fixtures/Profiles/matrix.json`  
Code: `PlatformCapabilityProfile.shipping(_:)`, `ExtensionExecutionPolicy.shipping(_:)`.

## What is **not** claimed

### Mac App Store (`mac-app-store`)

- Downloadable **native** Swift extension helpers that introduce or change functionality after install.
- Marketplace **downloadable Wasm** as a default stable feature.
- Silent enablement of native helpers if a binary happens to be present on disk — launch and install are **fail-closed**.

### iOS / iPadOS (`ios`)

- Downloadable native code.
- Arbitrary local process launch, PTY terminal, Git CLI.
- Local language-server processes (profile marks LS as **remote**).
- Unrestricted marketplace install of procedural extensions.
- Unrestricted downloadable Wasm that changes app functionality.

### All App Store profiles

- That native process isolation is a security sandbox (see ADR-015: reliability boundary only).
- That remote tooling is “download and run arbitrary code on device.”

## How feature flags work (technical)

1. Host selects `ShippingProfileID` at build or runtime configuration.
2. `PlatformCapabilityProfile.shipping` supplies the capability matrix.
3. `ExtensionExecutionPolicy.shipping` configures RuntimeSelector, native policy, Wasm origin gates.
4. `ShippingInstallPolicy` is injected into `ExtensionPackageManager` so install cannot smuggle native/Wasm past profile rules.
5. `RemoteToolingCoordinator` routes language-server work to **remote** when local LS is not `.local`.
6. Process sites (LSP, Tasks, Terminal, SCM, native helper transport) call `requireLocal` / profile checks **before** `Foundation.Process`.

Unsupported operations throw `CodeEditorPlatformError.unsupportedCapability` or structured host errors — they must not appear to succeed.

## Remote tooling model

On iOS (and when local tools are unavailable), procedural language features may run via **host-mediated remote providers** (`RemoteExtensionHost`, remote language-service adapters). The device binary does not download and exec arbitrary native helpers. Remote peers are connected through explicit transports configured by the host app.

## Bundled vs downloadable Wasm

| Origin | MAS / iOS default | Direct macOS |
|---|---|---|
| `ExtensionArtifactOrigin.bundled` | Allowed when `bundledWasm` is local | Allowed |
| `installed` / marketplace | Denied | Allowed (trust + SBOM) |

Apps that ship Wasm must include modules in the application bundle for MAS/iOS profiles.

## Trust, signing, revocation (direct macOS)

Phase 14 store controls: Ed25519 package signatures, fail-closed keyring, SBOM/license policy, revocation list, quarantine, atomic install/update/rollback. App Review for **direct** distribution still expects honest publisher verification and no private LaunchServices APIs (ADR-011).

## Privacy and telemetry

- Extension storage is quota-scoped under the host-owned storage root.
- Store telemetry is local NDJSON (install/update/rollback/deny); no source code or secrets.
- Hosts must not export user workspace content via extension grants without user-visible permission.

## Host binary checklist

- [ ] Set `ShippingProfileID` matching the target store / distribution.
- [ ] Pass `ExtensionExecutionPolicy.shipping(id)` into the orchestrator.
- [ ] Inject `ShippingInstallPolicy.shipping(id)` into the package manager.
- [ ] Do not re-enable `nativeExtensionProcess` on MAS/iOS without a separate legal review strategy.
- [ ] For iOS, provide remote tooling transports if advertising language intelligence.
- [ ] Ship only bundled Wasm if using Wasm on MAS/iOS.
- [ ] Review entitlements/sandbox for any local process tools enabled on MAS.
- [ ] Confirm UI uses `ArtifactRunnabilityDescriptor` reasons instead of silent failure.

## References

- Apple App Review Guidelines (esp. executable code and software distribution rules such as 2.5.2 / 4.7 as applicable at submission time)
- [ADR-015](../Architecture/ADR-015-extension-threat-model.md) threat model
- [ADR-016](../Architecture/ADR-016-platform-profiles.md) platform profiles
- [PHASE15-NOTES](../Architecture/PHASE15-NOTES.md)
- [TOOLCHAIN](../Architecture/TOOLCHAIN.md) native helper trust notice
