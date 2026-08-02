# Accessibility manual sign-off protocol (REL-N04)

Automated gates cover identifier hierarchy, focus order, reduce-motion handling, and rotor surface models.
The following scenarios require **manual sign-off** before a release candidate; automation cannot reliably cover them.

## Required manual scenarios

| ID | Scenario | Platform | Sign-off |
|---|---|---|---|
| A11Y-M01 | VoiceOver full pass of navigator → editor → inspector → utility → status bar | macOS | pending |
| A11Y-M02 | VoiceOver rotor: errors, symbols, folds, breakpoints, search results | macOS | pending |
| A11Y-M03 | Full keyboard access only (no pointer) across chrome and editor | macOS | pending |
| A11Y-M04 | Switch Control basic navigation of workbench chrome | macOS | pending |
| A11Y-M05 | Dynamic Type / larger text (where applicable host UI) | iOS | pending |
| A11Y-M06 | Increase Contrast / differentiate without color alone | macOS/iOS | pending |
| A11Y-M07 | Reduce Motion: pane transitions do not use large motion | macOS/iOS | pending |
| A11Y-M08 | Focus restoration after command palette / open quickly dismiss | macOS | pending |
| A11Y-M09 | IME composition (Japanese/Chinese/Korean) in editor | macOS/iOS | pending |
| A11Y-M10 | Screen reader announcement of diagnostics and search hits | macOS | pending |

## Process

1. Run `./scripts/check-accessibility.sh` (must pass).
2. Execute each manual scenario; record date, build SHA, and tester in the table (replace `pending`).
3. File defects for any failure; do not mark release residual empty until closed with regression tests.

Pre-alpha: manual cells may remain `pending`. RC/stable certification requires all signed.
