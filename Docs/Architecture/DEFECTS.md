# Defects register

Machine source: `Docs/Architecture/defects.json`. Do not hand-edit status without updating JSON.

Updated: 2026-08-01

| ID | Severity | Product | Status | Summary |
|---|---|---|---|---|
| PKG-001 | P0 | Package | fixed | Committed Packages/CodeEditorGrammars; root Package.swift has zero Grammars/ paths; archive rehearsal script |
| CI-004 | P1 | scripts | fixed | check-format.sh and check-wasi-sdk.sh are hard gates; CI installs tools |
| CI-008 | P1 | CI | fixed | Examples/iOS/CodeEditoriOSExample + xcodebuild test job |
| CI-009 | P1 | CI | fixed | Docs/Architecture/XCODE.pin + check-xcode-pin.sh |
| CI-010 | P1 | CI | fixed | export-source-archive-rehearsal.sh + CI source-archive-rehearsal |
| CI-011 | P1 | Examples | fixed | macOS/iOS example packages with xcodebuild test jobs |
| DOC-001 | P0 | CodeEditorCore | fixed | Atomic multi-edit |
| DOC-002 | P0 | CodeEditorDocuments | fixed | Transactional undo/redo |
| DOC-003 | P0 | CodeEditorCore | fixed | Exact offsets |
| DOC-004 | P0 | CodeEditorDocuments | fixed | Conflict-safe save |
| WSP-001 | P0 | CodeEditorWorkspace | fixed | Dirty-close coordinator |
| WSP-002 | P0 | CodeEditorWorkspace | fixed | Durable workspace edit journal |
| EXT-001 | P0 | CodeEditorExtensionAPI | fixed | Validated ExtensionID |
| EXT-002 | P0 | CodeEditorExtensionHost | fixed | File-set signature equality |
| EXT-003 | P0 | CodeEditorExtensionHost | fixed | Publisher binding |
| EXT-004 | P0 | CodeEditorExtensions | fixed | Fail-closed install |
| WASM-001 | P0 | CodeEditorWasmEngineWasmKit | fixed | Real WasmKit parse/instantiate/call |
| WASM-002 | P0 | CodeEditorWasmEngine | fixed | Real module execution tests pass |
| IOS-001 | P0 | CodeEditorView | fixed | Duplicate a11y removed |
| LSP-001 | P0 | CodeEditorLSP | fixed | Full-text debounce resync |
| TER-001 | P0 | CodeEditorTerminal | fixed | CGhosttyShim + GhosttySessionController + non-lossy PTY; pin file; workbench terminal |
| CI-001 | P1 | scripts | fixed | generate-release-evidence.sh produces artifacts from tests |
| CMD-001 | P1 | CodeEditorWorkbench | fixed | Registration tokens retained |
| CMD-002 | P1 | CodeEditorCommands | fixed | Chord state machine |
| LSP-002 | P1 | CodeEditorLSP | fixed | Register-before-send |
| LSP-003 | P1 | CodeEditorLSP | fixed | WorkspaceSnapshotResolver cross-file |
| DAP-001 | P1 | CodeEditorDAP | fixed | Register-before-send |
| TASK-001 | P1 | CodeEditorTasks | fixed | No fabricated offsets |
| TASK-002 | P1 | CodeEditorTasks | fixed | Rolling readiness window; dep requires ready |
| UI-001 | P1 | CodeEditorView | fixed | Grapheme UITextInput, selection rects, BiDi, marked subrange |
| SCM-001 | P1 | CodeEditorSourceControl | fixed | Rename + path containment |
| TS-001 | P1 | CodeEditorTreeSitter | fixed | TreeSitterLanguageRuntime actor; off-main load |
| WB-001 | P1 | CodeEditorWorkbench | fixed | Real utility panels |

