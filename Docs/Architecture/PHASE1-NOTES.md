# Phase 1 notes — Reproducible package & toolchain (complete)

## Goal

A clean checkout is a valid, deterministic Swift package on the exact supported toolchains (Xcode 26.4 / Swift 6). Grammar C sources are committed; format and WASI are hard gates; real macOS/iOS example hosts pass `xcodebuild test`.

## Exit criteria (all met)

| Criterion | Evidence |
|---|---|
| Fresh clone `swift package resolve` without prior scripts | Root `Package.swift` has **no** `Grammars/` paths; sources in `Packages/CodeEditorGrammars` |
| Core/View/Workbench build without grammar network | Independent products; path package sources committed |
| Language packs use committed artifacts | `Packages/CodeEditorGrammars` + typed `LanguagePackError` for missing queries |
| Source archive rehearsal | `./scripts/export-source-archive-rehearsal.sh` + CI job `source-archive-rehearsal` |
| Exact Xcode 26 pin | `Docs/Architecture/XCODE.pin` + `./scripts/check-xcode-pin.sh` |
| Hard format gate | `./scripts/check-format.sh` (no soft skip) |
| Hard WASI gate | `./scripts/check-wasi-sdk.sh` installs from pin URL |
| Real example hosts | `Examples/macOS/CodeEditorMacExample`, `Examples/iOS/CodeEditoriOSExample` + `xcodebuild test` |
| Test resources | Core/Extensions/Wasm fixtures via `resources:` where needed |

## PKG-001 design

1. **Root package** declares zero `path: "Grammars/..."` targets.
2. **`Packages/CodeEditorGrammars`** owns all `TreeSitter*Grammar` C targets and products.
3. Language products depend via `.product(name: "TreeSitter…", package: "CodeEditorGrammars")`.
4. `scripts/filter-package-grammars.py` is **retired** (fails if invoked).
5. `./scripts/update-grammars.sh` regenerates into the committed package path (maintainer only).
6. `./scripts/verify-grammars.sh` hard-checks pins + checksums (no network, no SKIP).

## Toolchain

See `Docs/Architecture/TOOLCHAIN.md`, `XCODE.pin`, `WASI-SDK.pin`.

## CI jobs (Phase 1 additions)

| Job | Role |
|---|---|
| `checks` | Xcode pin, isolation, verify-grammars, hard format, licenses, docs |
| `resolve-empty-cache` | Resolve/build without network grammar bootstrap |
| `source-archive-rehearsal` | `git archive` → empty dir → resolve/build products |
| `macos-example-app` | `swift test` + `xcodebuild test` (macOS) |
| `ios-example-app` | `xcodebuild test` (iOS Simulator) |
| `wasi-sdk` | Hard install/verify of pinned WASM SDK |

## Local verification

```bash
./scripts/check-xcode-pin.sh
./scripts/verify-grammars.sh
./scripts/check-format.sh
./scripts/check-wasi-sdk.sh
./scripts/check-product-isolation.sh
swift package resolve
swift build --product CodeEditorCore
swift build --product CodeEditorView
swift build --product CodeEditorWorkbench
swift build --product CodeEditorLanguageSwift
./scripts/export-source-archive-rehearsal.sh
# Example hosts:
(cd Examples/macOS/CodeEditorMacExample && swift test)
# xcodebuild test for macOS + iOS examples — see scripts/check-examples.sh
```

## Explicit non-goals (later phases)

- DOC/WSP/EXT/WASM/TER functional depth beyond package/toolchain
- Coverage threshold hard-fail (Phase 11)
- Full real-LSP session matrix (Phase 6)
- Optional Ghostty native library CDN build (pin required; link optional)
