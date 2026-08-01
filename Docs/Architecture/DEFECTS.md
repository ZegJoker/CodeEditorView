# Defect register (audit 2026-08 remediation)

**Source of truth:** `Docs/Architecture/defects.json`  
**Gate:** `./scripts/check-defects.sh` fails on any open/partial P0/P1.

| ID | Severity | Product | Status | Notes |
|---|---|---|---|---|
| PKG-001 | P0 | Package | closed | Grammar path policy + filter script |
| DOC-001 | P0 | CodeEditorCore | closed | Atomic multi-edit |
| DOC-002 | P0 | CodeEditorDocuments | closed | Transactional undo/redo |
| DOC-003 | P0 | CodeEditorCore | closed | Exact offsets |
| DOC-004 | P0 | CodeEditorDocuments | closed | Conflict-safe save |
| WSP-001 | P0 | CodeEditorWorkspace | closed | Dirty-close coordinator |
| WSP-002 | P0 | CodeEditorWorkspace | closed | Durable workspace-edit journal |
| EXT-001–004 | P0 | Extensions | closed | ID, file-set, publisher, fail-closed |
| WASM-001/002 | P0 | Wasm | closed | Real WasmKit parse/instantiate/call + tests |
| IOS-001 | P0 | CodeEditorView | closed | Duplicate a11y removed |
| LSP-001 | P0 | CodeEditorLSP | closed | Full-text debounce |
| TER-001 | P0 | CodeEditorTerminal | closed | CGhosttyShim, GhosttySessionController, pin, workbench terminal, non-lossy PTY |
| CI-001 | P1 | scripts | closed | `generate-release-evidence.sh` |
| CMD-001/002 | P1 | Commands/Workbench | closed | Tokens + chords |
| LSP-002/003 | P1 | CodeEditorLSP | closed | Register-before-send + cross-file snapshots |
| DAP-001 | P1 | CodeEditorDAP | closed | Register-before-send |
| TASK-001/002 | P1 | CodeEditorTasks | closed | Positions + streaming readiness deps |
| UI-001 | P1 | CodeEditorView | closed | Grapheme/IME/BiDi/selection rects |
| SCM-001 | P1 | CodeEditorSourceControl | closed | Rename + path security |
| TS-001 | P1 | CodeEditorTreeSitter | closed | LanguageRuntime actor + off-main load |
| WB-001 | P1 | CodeEditorWorkbench | closed | Real Output/Problems/Terminal panels |

## Process

Closing requires regression tests. Do not remove historical rows; append revisions in `defects.json`.
