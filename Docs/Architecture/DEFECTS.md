# Defects register

Machine source: `Docs/Architecture/defects.json`.

Updated: 2026-08-02

| ID | Severity | Product | Status | Summary |
|---|---|---|---|---|
| PKG-001 | P0 | Package | fixed | Committed Packages/CodeEditorGrammars; root Package.swift has zero Grammars/ paths; archive rehearsal script |
| CI-004 | P1 | scripts | fixed | check-format.sh and check-wasi-sdk.sh are hard gates; CI installs tools |
| CI-008 | P1 | CI | fixed | Examples/iOS/CodeEditoriOSExample + xcodebuild test job |
| CI-009 | P1 | CI | fixed | Docs/Architecture/XCODE.pin + check-xcode-pin.sh |
| CI-010 | P1 | CI | fixed | export-source-archive-rehearsal.sh + CI source-archive-rehearsal |
| CI-011 | P1 | Examples | fixed | macOS/iOS example packages with xcodebuild test jobs |
| DOC-001 | P0 | CodeEditorCore | fixed | Atomic multi-edit with staging buffer, overlap reject, equal-offset order, fault/property tests |
| DOC-002 | P0 | CodeEditorDocuments | fixed | Throwing undo/redo; stacks move only after success; dirty from savedVersion; no try? apply |
| DOC-003 | P0 | CodeEditorCore | fixed | Exact offsets; private scalarIndex throws; never EOF fallback |
| DOC-004 | P0 | CodeEditorDocuments | fixed | CAS save with expectedIdentity + revalidate; conflict SaveResult |
| WSP-001 | P0 | CodeEditorWorkspace | fixed | All UI close paths use requestClose*; leases fail-closed |
| WSP-002 | P0 | CodeEditorWorkspace | fixed | Fault matrix + duringRollback typed catastrophic |
| EXT-001 | P0 | CodeEditorExtensionAPI | fixed | Validated ExtensionID |
| EXT-002 | P0 | CodeEditorExtensionHost | fixed | File-set signature equality |
| EXT-003 | P0 | CodeEditorExtensionHost | fixed | Publisher binding |
| EXT-004 | P0 | CodeEditorExtensions | fixed | Fail-closed install |
| WASM-001 | P0 | CodeEditorWasmEngineWasmKit | fixed | Real WasmKit parse/instantiate/call |
| WASM-002 | P0 | CodeEditorWasmEngine | fixed | Real module execution tests pass |
| IOS-001 | P0 | CodeEditorView | fixed | Duplicate a11y removed; iOS example host from Phase 1 |
| LSP-001 | P0 | CodeEditorLSP | fixed | Full-text debounce resync |
| TER-001 | P0 | CodeEditorTerminal | fixed | CGhosttyShim + GhosttySessionController + non-lossy PTY; pin file; workbench terminal |
| CI-001 | P1 | scripts | fixed | generate-release-evidence.sh produces artifacts from tests |
| CMD-001 | P1 | CodeEditorWorkbench | fixed | RegistrationBag host lifetime + tests |
| CMD-002 | P1 | CodeEditorCommands | fixed | Chord SM: prefix, timeout short, Escape, layers |
| LSP-002 | P1 | CodeEditorLSP | fixed | Register-before-send |
| LSP-003 | P1 | CodeEditorLSP | fixed | WorkspaceSnapshotResolver cross-file |
| DAP-001 | P1 | CodeEditorDAP | fixed | Register-before-send |
| TASK-001 | P1 | CodeEditorTasks | fixed | No fabricated offsets |
| TASK-002 | P1 | CodeEditorTasks | fixed | Rolling readiness window; dep requires ready |
| UI-001 | P1 | CodeEditorView | fixed | Grapheme UITextInput/nav/delete; BiDi helpers; selection geometry; marked session |
| SCM-001 | P1 | CodeEditorSourceControl | fixed | Rename + path containment |
| TS-001 | P1 | CodeEditorTreeSitter | fixed | TreeSitterLanguageRuntime actor; lock-box env; no nonisolated(unsafe) globals |
| WB-001 | P1 | CodeEditorWorkbench | fixed | Real utility panels |
| DOC-005 | P0 | CodeEditorDocuments | fixed | Streaming readContentAndIdentity; no Data(contentsOf) identity path |
| DOC-006 | P1 | CodeEditorDocuments | fixed | CoordinatedFileIO once-resume box; test-proven |
| DOC-007 | P0 | CodeEditorDocuments | fixed | DocumentCodec rejects .other; no UTF-8 mojibake fallback; BOM preserve policy |
| DOC-008 | P0 | CodeEditorDocuments | fixed | Versioned recovery journal with SHA-256 checksum, quotas, 0600, quarantine |
| DOC-009 | P1 | CodeEditorCore | fixed | Bounded EditorEventStream/TextDocument streams (bufferingNewest) |
| DOC-010 | P1 | CodeEditorCore | fixed | DocumentStore no longer @unchecked Sendable; main-actor-affine documented |
| UI-002 | P0 | CodeEditorView | fixed | MarkedTextSession + applyMarkedText without undo registration |
| UI-003 | P1 | CodeEditorView | fixed | AppKit internal drag uses moveText transaction; external size guard |
| UI-004 | P1 | CodeEditorCore | fixed | WordNavigationMode codeSubword/camelCase/snake/acronym |
| UI-005 | P2 | CodeEditorView | fixed | EditorTextServicesPolicy code-editor defaults |
| UI-006 | P1 | CodeEditorView | fixed | Layout max-width cache; invalidate on edit |
| UI-007 | P1 | CodeEditorView | fixed | Virtualized accessibility value (viewport + line/col) |
| UI-008 | P2 | CodeEditorView | fixed | EditorSignposts + EditorPerformanceHarness budgets |
| UI-009 | P0 | CodeEditorView | fixed | AppKit insertText honors replacementRange |
| WSP-003 | P0 | CodeEditorWorkspace | fixed | RelativeWorkspacePath + path corpus |
| WSP-004 | P0 | CodeEditorWorkspace | fixed | FS actor + concurrent stress + cancel tests |
| WSP-005 | P1 | CodeEditorWorkspace | fixed | FSEvents recursive + overflow/rescan |
| WSP-006 | P0 | CodeEditorWorkspace | fixed | DocumentLeaseRegistry ref-count |
| WSP-007 | P1 | CodeEditorWorkspace | fixed | On-disk golden v1/v999/corrupt fixtures |
| CMD-003 | P1 | CodeEditorCommands | fixed | CommandContextSnapshot from focus/trust |
| CMD-004 | P1 | CodeEditorCommands | fixed | Typed notFound/disabled/unsupported on palette path |
