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
| EXT-001 | P0 | CodeEditorExtensionAPI | fixed | Validated ExtensionID + directoryKey path roots |
| EXT-002 | P0 | CodeEditorExtensionHost | fixed | File-set equality; reject extra/missing |
| EXT-003 | P0 | CodeEditorExtensionHost | fixed | Publisher subject bound; subject-swap deny |
| EXT-004 | P0 | CodeEditorExtensions | fixed | Fail-closed install + insecureForTests only for tests |
| EXT-005 | P0 | CodeEditorExtensions | fixed | Corrupt durable state quarantines store |
| EXT-006 | P0 | CodeEditorExtensions | fixed | SBOM/broker digests fail closed never length |
| EXT-007 | P0 | CodeEditorExtensionHost | fixed | Reject symlink/special/key-material package entries |
| EXT-008 | P1 | CodeEditorExtensionAPI | fixed | TOML fail-closed api_version + unknown required fields |
| EXT-009 | P0 | CodeEditorExtensions | fixed | Recover re-verifies package generations |
| EXT-010 | P1 | CodeEditorExtensionHost | fixed | Storage quota overwrite-correct + directoryKey keys |
| EXT-011 | P1 | CodeEditorExtensionHost | fixed | Durable settings under storage root |
| EXT-012 | P0 | CodeEditorExtensionHost | fixed | Streaming download mid-stream caps + redirect guard |
| EXT-013 | P0 | CodeEditorExtensionHost | fixed | Host-owned npm materializer no soft-stub |
| EXT-014 | P0 | CodeEditorExtensionHost | fixed | Process allowlist canonical/trusted-dir paths |
| EXT-015 | P1 | CodeEditorExtensionHost | fixed | Multi-root worktree + read limits + revoke |
| EXT-016 | P1 | CodeEditorExtensionHost | fixed | ExtensionSDKConformance kit |
| WASM-001 | P0 | CodeEditorWasmEngineWasmKit | fixed | WasmKit parse/instantiate/call; bytes determine behavior |
| WASM-002 | P0 | CodeEditorWasmEngine | fixed | Real module + interrupt/hostile containment tests |
| WASM-003 | P0 | CodeEditorWasmEngineWasmKit | fixed | Host imports read guest linear memory OOB-safe |
| WASM-004 | P0 | CodeEditorWasmEngineWasmKit | fixed | Wall-time + cooperative cancel interrupt |
| WASM-005 | P1 | CodeEditorWasmEngine | fixed | Memory limit/OOB enforcement |
| WASM-006 | P0 | CodeEditorWasmEngineTests | fixed | Hostile fixture suite on WasmKit |
| WASM-007 | P1 | CodeEditorExtensionHost | fixed | Dual-run contract LinkedGuest vs WasmKit |
| WASM-008 | P1 | CodeEditorWasmEngine | fixed | Simulation alias = LinkedGuest; WasmKit is real |
| WASM-009 | P1 | CodeEditorWasmEngine | fixed | Fixture gate script + session lifecycle |
| IOS-001 | P0 | CodeEditorView | fixed | Duplicate a11y removed; iOS example host from Phase 1 |
| LSP-001 | P0 | CodeEditorLSP | fixed | Full-text debounce + rapid-edit matrix vs mock server |









| CI-001 | P1 | scripts | fixed | generate-release-evidence.sh produces artifacts from tests |
| CMD-001 | P1 | CodeEditorWorkbench | fixed | RegistrationBag host lifetime + tests |
| CMD-002 | P1 | CodeEditorCommands | fixed | Chord SM: prefix, timeout short, Escape, layers |
| LSP-002 | P1 | CodeEditorLSP | fixed | Register-before-send actor path; earlyResponses bounded |
| LSP-003 | P1 | CodeEditorLSP | fixed | WorkspaceSnapshotResolver; cross-file tests retained |
| DAP-001 | P1 | CodeEditorDAP | fixed | Register-before-send; ordered inbound; earlyResponses bounded |
| TASK-001 | P1 | CodeEditorTasks | fixed | Snapshot-only range resolve; zero fabricated offsets |
| TASK-002 | P1 | CodeEditorTasks | fixed | Streaming matcher across chunks + multiline EOF flush |
| UI-001 | P1 | CodeEditorView | fixed | Grapheme UITextInput/nav/delete; BiDi helpers; selection geometry; marked session |
| SCM-001 | P1 | CodeEditorSourceControl | fixed | Porcelain -z rename/unicode/conflict/copy fixtures |
| TS-001 | P1 | CodeEditorTreeSitter | fixed | LanguageDocumentActor off-main; provider delegates highlights |
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
| TER-001 | P0 | CodeEditorTerminal | fixed | GhosttySessionController + TerminalService; pin; fail-closed unlinked |
| TER-002 | P0 | CodeEditorTerminal | fixed | ce_pty_spawn C helper; exclusive FD; EAGAIN wait |
| TER-003 | P0 | CodeEditorTerminal | fixed | Ordered transport; overflow fatal; no silent drop |
| TER-004 | P0 | CodeEditorTerminalGhostty | fixed | GhosttySurfaceView + workbench Ghostty panel |
| TER-005 | P1 | CodeEditorTerminal | fixed | TerminalService sessions/close/restore config |
| TER-006 | P1 | CodeEditorDAP | fixed | runInTerminal → TerminalService debuggee |
| TER-007 | P1 | CodeEditorTerminal | fixed | Security policy + a11y adapter |
| TER-008 | P0 | CodeEditorTerminal | fixed | Workbench path without TerminalScreen feed |
| LSP-004 | P1 | CodeEditorLSP | fixed | Ordered inbound notification/request chain |
| LSP-005 | P1 | CodeEditorLSP | fixed | negotiatedPositionEncoding stored on session |
| LSP-006 | P1 | CodeEditorLSP | fixed | Dynamic registration tracks methods |
| LSP-007 | P1 | CodeEditorLSP | fixed | applyEdit plan path (WorkspaceEditPlan) retained + tests |
| LSP-008 | P1 | CodeEditorLSP | fixed | LSPDiagnosticStore version-aware clear on empty/server |
| LSP-009 | P1 | CodeEditorLSP | fixed | scripts/check-real-lsp.sh hard when REQUIRE_REAL_LSP=1 |
| TS-002 | P1 | CodeEditorTreeSitter | fixed | Generation-tagged highlights; stale discarded |
| TASK-003 | P1 | CodeEditorTasks | fixed | Cancel waits process death; exclusive slot held until exit |
| TASK-004 | P1 | CodeEditorTasks | fixed | Bounded output single marker; unresolved vars throw |
| TASK-005 | P1 | CodeEditorTasks | fixed | FakeTaskRunner only in Tests/CodeEditorTasksTests |
| DAP-002 | P1 | CodeEditorDAP | fixed | Ordered inbound chain + lifecycle failed/terminated |
| DAP-003 | P1 | CodeEditorDAP | fixed | runInTerminal Ghostty/TerminalService + trust deny |
| SCM-002 | P1 | CodeEditorSourceControl | fixed | Trust-gated Git; per-op handles; component path check |
| PROC-001 | P1 | CodeEditorCore | fixed | ProcessSupervisor alias; tasks/Git share ProcessService |
| WB-007 | P1 | CodeEditorWorkbench | fixed | Problems/SCM/Debug models with unit tests |
