# Toolchain and WASI pins

## Swift / Xcode (hard pin)

| Item | Pin |
|---|---|
| Package tools version | `6.0` (`Package.swift` `swift-tools-version`) |
| Language mode | Swift 6 (`.v6`) |
| Platforms | macOS 15+, iOS 18+ |
| `.swift-version` | `6.0` (local `swiftenv` / tooling hint) |
| **Xcode marketing version** | **26.4** (`Docs/Architecture/XCODE.pin`) |
| Xcode build (reference) | `17E192` |
| Swift compiler (reference) | 6.3.x on Xcode 26.4 |
| CI runner image | `macos-15` |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` |

CI selects and verifies the pin via `./scripts/check-xcode-pin.sh` (hard fail on marketing version mismatch). Every evidence artifact records `xcodebuild -version` and `swift --version`.

## Format (hard gate)

| Item | Value |
|---|---|
| Tool | `swift-format` on `PATH` |
| Config | `.swift-format` |
| Script | `./scripts/check-format.sh` |
| Policy | Missing tool **or** any lint finding → **exit 1** (no soft skip) |

Install: `brew install swift-format`

## Swift WASI SDK (hard gate)

Pinned for CI presence validation (Phase 1). Real Wasm execution is Phase 9 / ADR-017; Phase 11 is §26 qualification.

| Item | Value |
|---|---|
| Pin file | `Docs/Architecture/WASI-SDK.pin` |
| Install URL / checksum | in pin file (`INSTALL_URL`, `INSTALL_CHECKSUM`) |
| Env overrides | `CODEEDITOR_WASI_SDK_ID`, `CODEEDITOR_WASI_SDK_URL`, `CODEEDITOR_WASI_SDK_CHECKSUM` |
| CI job | `wasi-sdk` in `.github/workflows/ci.yml` |
| Script | `./scripts/check-wasi-sdk.sh` (installs if missing; **fails** if pin absent) |

```bash
./scripts/check-wasi-sdk.sh
swift sdk list | grep -F swift-6.3.3-RELEASE_wasm
```

## Grammar pins (committed package)

| Item | Value |
|---|---|
| Committed sources | `Packages/CodeEditorGrammars/Sources/<lang>/` |
| Package | `Packages/CodeEditorGrammars` (path dependency) |
| Pin catalog | `scripts/grammars.tsv` (SHA-40 + parser.c checksum) |
| Verify | `./scripts/verify-grammars.sh` (hard; no network) |
| Maintainer regen | `./scripts/update-grammars.sh` then commit package sources |

A clean clone resolves **without** running `update-grammars.sh`. That script is only for intentional upstream pin upgrades.

## Ghostty

| Item | Value |
|---|---|
| Pin file | `Docs/Architecture/GHOSTTY.pin` |
| Checkout/build | `./scripts/build-ghostty.sh` (optional link via `CODEEDITOR_GHOSTTY_LINKED=1`) |

## Native extension helper trust (Phase 1 policy record)

Per ADR-015:

- Native Swift process helpers are a **reliability** boundary, not a security sandbox.
- Default: **trusted-signed** or **workspace-dev** only; untrusted helpers prohibited without OS sandbox.
- MAS / iOS profiles mark `nativeExtensionProcess` unavailable by default.
