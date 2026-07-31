# Toolchain and WASI pins

## Swift toolchain

| Item | Pin |
|---|---|
| Package tools version | `6.0` (`Package.swift` `swift-tools-version`) |
| Language mode | Swift 6 (`.v6`) |
| Platforms | macOS 15+, iOS 18+ |
| `.swift-version` | `6.0` (local `swiftenv` / tooling hint) |
| CI Xcode image | `macos-15` (or `macos-latest` with Xcode 16+) |

Phase 0 local baseline also validated on Apple Swift 6.3 developer toolchain; the package remains compatible with Swift 6.0 tools version.

## Swift WASI SDK (extension Swift-Wasm path)

Pinned for CI presence validation (Phase 1). Phase 11 adds **build/repro scripts**; ABI freeze blocked until CI emits real `.wasm` (ADR-017).

| Item | Value |
|---|---|
| Pin file | `Docs/Architecture/WASI-SDK.pin` |
| Env override | `CODEEDITOR_WASI_SDK_ID` |
| CI job | `wasi-sdk` in `.github/workflows/ci.yml` |
| Build script | `scripts/build-wasm-extension.sh` |
| Fixture check | `scripts/check-wasm-fixture.sh` |

Install (example; adjust to the pin file):

```bash
swift sdk install "$CODEEDITOR_WASI_SDK_URL"
swift sdk list | grep -F "$(grep -v '^#' Docs/Architecture/WASI-SDK.pin | head -1)"
./scripts/build-wasm-extension.sh ConformanceExtensionGuest
./scripts/check-wasm-fixture.sh
```

## Grammar pins

Immutable Tree-sitter grammar commits live in `scripts/grammars.tsv` (SHA-40 + parser.c checksum).  
Validate with `./scripts/check-grammar-pins.sh`. Refresh with `./scripts/record-grammar-pins.sh` only as an intentional upgrade.

## Native extension helper trust (Phase 1 policy record)

Per ADR-015:

- Native Swift process helpers are a **reliability** boundary, not a security sandbox.
- Default: **trusted-signed** or **workspace-dev** only; untrusted helpers prohibited without OS sandbox.
- MAS / iOS profiles mark `nativeExtensionProcess` unavailable by default.
