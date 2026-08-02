# Phase 10 notes — Xcode-like workbench experience

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md`  
- Phase gate: **§ Phase 10**  
- Findings: **§10.1–10.6**

**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD; no ContentUnavailable-only supported surfaces.

> Prior `PHASE10-NOTES` described native Swift process runtime (pre-audit numbering). That work lives under extension host phases. **Audit Phase 10 is the workbench shell.**

## Goal

Compose foundations into an IDE-quality shell: navigators, tabs, schemes, status/activity, commands, search/problems, SCM/terminal/debug/test workflows, Open Quickly modes, dirty close, and FullWorkbench sample wiring.

## Navigator inventory (E1)

| ID | Model |
|---|---|
| `workbench.navigator.files` | File tree |
| `workbench.navigator.symbols` | `WorkbenchSymbolsModel` |
| `workbench.navigator.search` / `fullworkbench.navigator.find` | Host find + shell search |
| `workbench.navigator.issues` | `WorkbenchTaskProblemsBridge` |
| `workbench.navigator.tests` | `WorkbenchTestsModel` |
| `workbench.navigator.debug` | `WorkbenchDebugModel` |
| `workbench.navigator.scm` / host SCM | `WorkbenchSCMModel` |
| `workbench.navigator.breakpoints` | `WorkbenchBreakpointsModel` |

Empty lists use real empty-state chrome (not “coming soon” stubs).

## Chrome models

| Model | Role |
|---|---|
| `WorkbenchSchemeModel` | Schemes, run destinations, build/test/run task IDs |
| `WorkbenchActivityModel` | Progress stack + cancel |
| `WorkbenchStatusMetrics` | Line/col via `LineIndex` (O(log n)) |
| `OpenQuicklyModel` | file/symbol/command modes + `path:line:col` |
| `WorkbenchChromeCommand` | Command ID matrix for primary chrome actions |

## FullWorkbench E2E map

Sample project + `HostServices`:

1. Open workspace / `Main.swift`  
2. Edit in editor (preview promote / pin APIs in workspace)  
3. Find navigator search/replace preview  
4. Scheme tasks: `sample.build` / `sample.test` / `sample.echo`  
5. Problems from task diagnostics  
6. Debug/breakpoints/tests navigators (models populated by host)  
7. Ghostty terminal utility  
8. SCM status (trusted Git)  
9. Restore chrome / multi-window registry  
10. Dirty close via `requestClose*`  

## Gate evidence

```text
swift test --filter 'Phase10Workbench'
# Phase10 workbench chrome suite — passed

./scripts/check-defects.sh
```

### Exit map

| # | Proof |
|---|---|
| E1 | `navigatorInventoryCompleteOnDefaultWorkbench` |
| E2–E3 | Tab pin helpers + existing lifecycle tests |
| E4 | `schemeResolvesBuildTestRunTasks`, default schemes |
| E5 | `statusLineColumnUsesLineIndexNotScanSemantics` |
| E6 | `activityCancelRemovesItem` |
| E7 | `chromeCommandsAreDistinctCommandIDs` |
| E8–E12 | Open Quickly modes/location; problems/SCM models |
| E13–E15 | Phase 4 close paths; a11y IDs on navigators |
| E16 | This file + FullWorkbench host wiring |

## Forbidden residuals

- ContentUnavailable as sole body for listed navigators  
- Full-string status line/col scan  
- Scheme actions with no task id resolution  
- PHASE10-NOTES claiming process runtime as Phase 10  

## Related

- Phase 4 dirty close / multi-window  
- Phase 5 Ghostty terminal  
- Phase 7 problems/SCM/debug models  
- Audit Phase 11 stabilization (next)  
