# Platform build / runtime matrix (UI-N08)

**Policy:** Apple silicon–only continuous testing. Intel macOS is **not** promised;
hosts that require Intel must run their own validation. Package platforms remain
`macOS 15+` and `iOS 18+` (see `Package.swift`).

## Required matrix

| Platform | Runtime class | Toolchain | Evidence |
|----------|---------------|-----------|----------|
| macOS 15 (oldest supported) | macOS 15.x Apple silicon | Swift 6 / Xcode per `TOOLCHAIN.md` | `swift test` + unit/UI host smoke |
| macOS latest supported | latest stable macOS Apple silicon | Xcode 26 toolchain when available; otherwise current pin | `swift test` + example hosts |
| iOS 18 simulator | iOS 18 simulator (Apple silicon host) | same as macOS pin | `xcodebuild` test when Xcode available |
| iOS latest simulator | latest supported iOS simulator | same | `xcodebuild` test when Xcode available |

## Hard gates

1. **Package platforms** must declare `.macOS(.v15)` and `.iOS(.v18)` (or newer only with matrix update).
2. **This document** must remain the source of truth for silicon-only policy.
3. **`Scripts/check-platform-matrix.sh`** fails CI if this document or package platforms drift.
4. Environment gaps (no iOS simulator on a given agent) are recorded under blockers; production paths still require real platform builds—never ship fakes as defaults.

## Local verification

```bash
./Scripts/check-platform-matrix.sh
swift test --filter 'UIN08|UIN0'
```

## Automation notes

- Unit tests under `Tests/CodeEditorViewTests/UINAuditTests.swift` encode UI-N01…UI-N10 contracts and run on macOS CI.
- Full UIKit `UITextInput` host tests require an iOS simulator agent; the pure engines (`CaretNavigationEngine`, `SelectionGeometry`, `NativeInputContracts`, `WritingDirectionModel`) are platform-neutral and covered on macOS.
