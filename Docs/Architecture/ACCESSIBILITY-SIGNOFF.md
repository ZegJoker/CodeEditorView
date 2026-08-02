# Accessibility sign-off protocol (REL-N04)

## Automated coverage (must pass in CI)

`scripts/check-accessibility.sh` runs executable automation via `WorkbenchAccessibilitySession`
(library XCUI-equivalent hierarchy / keyboard / rotor / Switch Control driver):

| ID | Scenario | Automation |
|---|---|---|
| A11Y-A01 | Accessibility hierarchy IDs for chrome regions | `WorkbenchAccessibilitySession.hierarchyIdentifiers` |
| A11Y-A02 | Keyboard-only tab order across navigator/editor/inspectors/panels | `moveFocus` |
| A11Y-A03 | Rotor surfaces: errors, symbols, folds, breakpoints, search | `rotorQuery` / `selectRotorHit` |
| A11Y-A04 | Switch Control linear scan + select (fail-closed throws when disabled) | `switchControlScan` / `switchControlSelect` → `WorkbenchAccessibilityError.switchControlDisabled` |
| A11Y-A05 | Reduce Motion disables large chrome motion | preferences.reduceMotion |
| A11Y-A06 | High contrast + Dynamic Type knobs honored | `chromePresentationValid` |
| A11Y-A07 | Focus restoration after palette / open quickly | `dismissTransientAndRestoreFocus` |
| A11Y-A08 | Full keyboard access gate | preferences.fullKeyboardAccess |
| A11Y-A09 | Live AppKit AX tree of hosted `WorkbenchView` (NSHostingController + NSView anchors) | `WorkbenchAccessibilityTreeProbe.collectLiveAccessibilityTree` |

Regression tests: `test_REL_N04_*` under `Tests/CodeEditorWorkbenchTests` and `Tests/ReleaseTruthTests`.

## Manual residual scenarios

Automation cannot reliably cover live VoiceOver speech or IME engines. These remain manual for RC:

| ID | Scenario | Platform | Sign-off |
|---|---|---|---|
| A11Y-M01 | Live VoiceOver speech pass of navigator → editor → inspector → utility → status bar | macOS | pending (pre-alpha) |
| A11Y-M09 | IME composition (Japanese/Chinese/Korean) in editor | macOS/iOS | pending (pre-alpha) |
| A11Y-M10 | Live screen reader announcement of diagnostics and search hits | macOS | pending (pre-alpha) |

Pre-alpha: manual residual cells may remain `pending`. RC/stable certification requires all signed.
Keyboard/rotor/Switch Control/high-contrast/Dynamic Type/reduce-motion/focus restoration are **automated** above — not manual-only.

## Process

1. Run `./scripts/check-accessibility.sh` (must pass; runs `swift test --filter REL_N04`).
2. For RC: execute residual manual scenarios; record date, build SHA, and tester.
3. File defects for any failure; do not empty release residual until closed with regression tests.
