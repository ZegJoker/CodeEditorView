# Platform build / runtime matrix (UI-N08)

**Policy:** Apple silicon–only continuous testing. Intel macOS is **not** promised;
hosts that require Intel must run their own validation. Package platforms remain
`macOS 15+` and `iOS 18+` (see `Package.swift`).

## Required matrix

| Platform | Runtime class | Toolchain | Evidence |
|----------|---------------|-----------|----------|
| macOS 15 (oldest supported) | macOS 15.x Apple silicon | Swift 6 / Xcode per `TOOLCHAIN.md` | `swift build --product CodeEditorView` + `swift test` |
| macOS latest supported | latest stable macOS Apple silicon | Xcode 26 toolchain when available; otherwise current pin | same + example `xcodebuild build` |
| iOS 18 simulator | iOS 18 simulator (Apple silicon host) | same as macOS pin | `swift build --triple arm64-apple-ios18.0-simulator` |
| iOS latest simulator | latest supported iOS simulator | same | example `xcodebuild build` (iOS Simulator) |

## Hard gates

1. **Package platforms** must declare `.macOS(.v15)` and `.iOS(.v18)` (or newer only with matrix update).
2. **This document** must remain the source of truth for silicon-only policy.
3. **`scripts/check-platform-matrix.sh`** fails CI if documentation, package platforms, or **real builds** fail.
4. The script always executes:
   - host `swift build --product CodeEditorView` (macOS)
   - iOS Simulator triple `swift build` for `arm64-apple-ios18.0-simulator`
   - requires `xcodebuild` on `PATH` and `arm64` host
5. When `CI=true` or `PLATFORM_MATRIX_XCODEBUILD=1`, the script also runs:
   - `Examples/macOS/CodeEditorMacExample` `xcodebuild build` (platform=macOS)
   - `Examples/iOS/CodeEditoriOSExample` `xcodebuild build` (iOS Simulator)
6. Evidence is written to `Baselines/evidence/platform-matrix.json` (required artifact).
7. Environment gaps are recorded under blockers; production paths still require real platform builds—never ship fakes as defaults.

## Local verification

```bash
# Core builds (macOS + iOS simulator triple)
./scripts/check-platform-matrix.sh

# Full matrix including example xcodebuild hosts
PLATFORM_MATRIX_XCODEBUILD=1 ./scripts/check-platform-matrix.sh

# Unit contracts
swift test --filter 'UIN0'
```

## Automation notes

- CI job `Platform matrix evidence (UI-N08)` runs `./scripts/check-platform-matrix.sh` (with CI → xcodebuild hosts).
- Separate CI jobs also run full `swift test`, iOS simulator SPM triple, and example host tests (`scripts/check-examples.sh`).
- Pure engines (`CaretNavigationEngine`, `SelectionGeometry`, `NativeInputContracts`, `WritingDirectionModel`) are platform-neutral and covered on macOS; UIKit hosts use the same engines via `EditorController.visualCaretMove`.
