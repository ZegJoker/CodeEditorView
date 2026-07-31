# Phase 1 notes — CI, reproducibility, platform contracts

## Goal

Every PR can resolve from empty caches; process-backed APIs fail closed on unsupported platforms; grammar pins are immutable; CI enforces isolation/docs/tests/API smoke.

## Deliverables status

| Source-plan item | Status |
|---|---|
| macOS debug/release test matrix | `.github/workflows/ci.yml` jobs `macos-debug`, `macos-release` |
| iOS Simulator build | job `ios-simulator` (SPM triple + iphonesimulator SDK) |
| Strict concurrency build | job `strict-concurrency` (`-strict-concurrency=complete`, warnings-as-errors) |
| Independent product smoke | `scripts/smoke-products.sh` + job `product-smoke` |
| API diff / symbol graphs | `scripts/check-api-baseline.sh` + job `api-diff` |
| Coverage | job `coverage` (`swift test --enable-code-coverage`) |
| Docs / isolation / format / license | job `checks` + scripts |
| Empty-cache resolve | job `resolve-empty-cache` |
| Platform service abstractions | `Sources/CodeEditorCore/Platform/*` |
| Process fail-closed | All five `Process()` sites + tests |
| Immutable grammar pins | `scripts/grammars.tsv` 40-char SHAs; `check-grammar-pins.sh` |
| Swift toolchain pin | `.swift-version`, `Docs/Architecture/TOOLCHAIN.md` |
| Swift WASI SDK job | `Docs/Architecture/WASI-SDK.pin`, `scripts/check-wasi-sdk.sh`, job `wasi-sdk` |

## Platform profiles (ADR-016)

Implemented as `PlatformCapabilityProfile` presets:

| Preset | Name |
|---|---|
| Direct-distribution macOS | `.directMacOS` |
| Mac App Store | `.macAppStore` |
| iOS | `.iOS` |
| Enterprise | `.enterprise` |
| Test | `.test` |
| Injected denial | `.processUnavailable` |

`PlatformCapabilityProfile.default()` maps macOS → directMacOS, iOS → iOS.

### Process() inventory (fail-closed)

| Site | Capability |
|---|---|
| `LSPProcessTransport.init` | `.localLanguageServerProcess` |
| `ProcessTaskRunner.run` | `.localProcess` |
| `ProcessTerminalBackend.start` | `.localProcess` (PTY reserved for Phase 7) |
| `GitCLIProvider.run` | `.localGitCLI` |
| `ProcessRemoteExtensionTransport.init` | `.nativeExtensionProcess` |

Each accepts optional `platformProfile:` (default `.default()`). Tests inject `.processUnavailable` and assert `CodeEditorPlatformError.unsupportedCapability` **before** process start.

Service protocols: `ProcessLaunching`, `PTYAccess`, `FileSystemAccess`, `NetworkAccess` + `PlatformServices` bundle.

## Grammar provenance

- Format: `name|c_symbol|url|commit_sha|sha256_parser_c`
- **39** languages pinned to full commit SHAs (no `main`/`master` pins)
- `./scripts/check-grammar-pins.sh` fails on mutable refs
- `./scripts/record-grammar-pins.sh` regenerates pins from clone cache
- `./scripts/update-grammars.sh` checks out by SHA when pin is 40 hex chars

## Toolchain / WASI

See `Docs/Architecture/TOOLCHAIN.md` and `Docs/Architecture/WASI-SDK.pin`.

- Package tools: Swift 6.0
- WASI pin: `swift-6.3.3-RELEASE_wasm` (install validated in CI when `WASI_SDK_REQUIRED=1` + URL secret)

## Native helper trust policy (Phase 1 record)

Per ADR-015 / TOOLCHAIN.md:

- Native process helpers are reliability boundaries only.
- Default profiles: trusted-signed / workspace-dev; MAS and iOS deny `nativeExtensionProcess`.
- Untrusted marketplace natives require OS sandbox (not claimed here).

## Local verification

```bash
./scripts/verify-local.sh
# or stepwise:
./scripts/check-grammar-pins.sh
./scripts/update-grammars.sh   # if Grammars/ missing
./scripts/check-product-isolation.sh
./scripts/check-docs.sh
./scripts/check-licenses.sh
swift test
```

## Gate criteria

| Criterion | Evidence |
|---|---|
| Empty-cache resolve path | CI job `resolve-empty-cache` |
| No false iOS local process | Profile defaults + unit tests on all process products |
| All Phase 1 deliverables landed | This document + scripts + workflow |

## Follow-ups (not Phase 1 scope)

- Phase 2: Core/Documents safety
- Phase 7: real PTY (switch terminal guard to `.localPTY`)
- Phase 11: Wasm guest runtime / ABI (WASI SDK **pin** is Phase 1)
- Tighten `STRICT_API_BASELINE=1` / digester semantic diffs once baselines committed
- `STRICT_FORMAT=1` once codebase is format-clean
