# Defects register

Machine source: `Docs/Architecture/defects.json` (REL-N03).

Updated: 2026-08-02

Every **fixed** row must list `regression_tests` that exist under `Tests/` or hard gate scripts.
`./scripts/check-defects.sh` verifies links; `DEFECTS_ALLOW_OPEN=1` validates structure only.

| ID | Severity | Product | Status | Summary | Regression tests |
|---|---|---|---|---|---|
| PKG-001 | P0 | Package | fixed | Committed Packages/CodeEditorGrammars; root Package.swift has zero Grammars/ paths; archive rehearsal script | scripts/export-source-archive-rehearsal.sh, Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| CI-004 | P1 | scripts | fixed | check-format.sh and check-wasi-sdk.sh are hard gates; CI installs tools | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, scripts/check-defects.sh |
| CI-008 | P1 | CI | fixed | Examples/iOS/CodeEditoriOSExample + xcodebuild test job | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| CI-009 | P1 | CI | fixed | Docs/Architecture/XCODE.pin + check-xcode-pin.sh | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| CI-010 | P1 | CI | fixed | export-source-archive-rehearsal.sh + CI source-archive-rehearsal | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| CI-011 | P1 | Examples | fixed | macOS/iOS example packages with xcodebuild test jobs | scripts/check-examples.sh |
| DOC-001 | P0 | CodeEditorCore | fixed | Atomic multi-edit with staging buffer, overlap reject, equal-offset order, fault/property tests | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| DOC-002 | P0 | CodeEditorDocuments | fixed | Throwing undo/redo; stacks move only after success; dirty from savedVersion; no try? apply | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| DOC-003 | P0 | CodeEditorCore | fixed | Exact offsets; private scalarIndex throws; never EOF fallback | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| DOC-004 | P0 | CodeEditorDocuments | fixed | CAS save with expectedIdentity + revalidate; conflict SaveResult | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| WSP-001 | P0 | CodeEditorWorkspace | fixed | All UI close paths use requestClose*; Close Pane wired; leases fail-closed | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| WSP-002 | P0 | CodeEditorWorkspace | fixed | Full fault matrix + duringRollback inject surfaces catastrophic/rollbackFailed | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| EXT-001 | P0 | CodeEditorExtensionAPI | fixed | Validated ExtensionID + directoryKey path roots | Tests/CodeEditorExtensionAPITests/ExtensionAPITests.swift |
| EXT-002 | P0 | CodeEditorExtensionHost | fixed | File-set equality; reject extra/missing | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-003 | P0 | CodeEditorExtensionHost | fixed | Publisher subject bound; subject-swap deny | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-004 | P0 | CodeEditorExtensions | fixed | Fail-closed install + insecureForTests only for tests | Tests/CodeEditorExtensionsTests/ExtensionRuntimeTests.swift, Tests/CodeEditorExtensionsTests/Phase8StoreSecurityTests.swift |
| WASM-001 | P0 | CodeEditorWasmEngineWasmKit | fixed | WasmKit parse/instantiate/call; bytes determine behavior | Tests/CodeEditorWasmEngineTests/RealWasmExecutionTests.swift |
| WASM-002 | P0 | CodeEditorWasmEngine | fixed | Real module + interrupt/hostile containment tests | Tests/CodeEditorWasmEngineTests/WasmEngineTests.swift, Tests/CodeEditorWasmEngineTests/Phase9WasmExecutionTests.swift |
| IOS-001 | P0 | CodeEditorView | fixed | Duplicate a11y removed; iOS example host from Phase 1 | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| LSP-001 | P0 | CodeEditorLSP | fixed | Full-text debounce + rapid-edit matrix vs mock server | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| TER-001 | P0 | CodeEditorTerminal | fixed | GhosttySessionController + TerminalService production path; pin; fail-closed unlinked | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| CI-001 | P1 | scripts | fixed | generate-release-evidence.sh produces artifacts from tests | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, scripts/check-defects.sh |
| CMD-001 | P1 | CodeEditorWorkbench | fixed | RegistrationBag host lifetime; contributions survive build | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| CMD-002 | P1 | CodeEditorCommands | fixed | Chord prefix wait + timeout short + Escape + layer tests | Tests/CodeEditorCommandsTests/CommandSystemTests.swift, Tests/CodeEditorCommandsTests/Phase4CommandTests.swift |
| LSP-002 | P1 | CodeEditorLSP | fixed | Register-before-send actor path; earlyResponses bounded | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-003 | P1 | CodeEditorLSP | fixed | WorkspaceSnapshotResolver; cross-file tests retained | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| DAP-001 | P1 | CodeEditorDAP | fixed | Register-before-send; ordered inbound; earlyResponses bounded | Tests/CodeEditorDAPTests/DAPSessionTests.swift, Tests/CodeEditorDAPTests/Phase7DAPTests.swift |
| TASK-001 | P1 | CodeEditorTasks | fixed | Snapshot-only range resolve; zero fabricated offsets | Tests/CodeEditorTasksTests/TaskTests.swift, Tests/CodeEditorTasksTests/Phase7TaskTests.swift |
| TASK-002 | P1 | CodeEditorTasks | fixed | Streaming matcher across chunks + multiline EOF flush | Tests/CodeEditorTasksTests/TaskTests.swift, Tests/CodeEditorTasksTests/Phase7TaskTests.swift |
| UI-001 | P1 | CodeEditorView | fixed | Grapheme UITextInput/nav/delete; BiDi helpers; selection geometry; marked session | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| SCM-001 | P1 | CodeEditorSourceControl | fixed | Porcelain -z rename/unicode/conflict/copy fixtures | Tests/CodeEditorSourceControlTests/SCMTests.swift, Tests/CodeEditorSourceControlTests/Phase7SCMTests.swift |
| TS-001 | P1 | CodeEditorTreeSitter | fixed | LanguageDocumentActor off-main; provider delegates highlights | Tests/CodeEditorTreeSitterTests/Phase6TreeSitterTests.swift |
| WB-001 | P1 | CodeEditorWorkbench | fixed | Real utility panels | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| DOC-005 | P0 | CodeEditorDocuments | fixed | Streaming readContentAndIdentity; no Data(contentsOf) identity path | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| DOC-006 | P1 | CodeEditorDocuments | fixed | CoordinatedFileIO once-resume box; test-proven | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| DOC-007 | P0 | CodeEditorDocuments | fixed | DocumentCodec rejects .other; no UTF-8 mojibake fallback; BOM preserve policy | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| DOC-008 | P0 | CodeEditorDocuments | fixed | Versioned recovery journal with SHA-256 checksum, quotas, 0600, quarantine | Tests/CodeEditorDocumentsTests/TextDocumentTests.swift, Tests/CodeEditorDocumentsTests/DocumentIOSafetyTests.swift |
| DOC-009 | P1 | CodeEditorCore | fixed | Bounded EditorEventStream/TextDocument streams (bufferingNewest) | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| DOC-010 | P1 | CodeEditorCore | fixed | DocumentStore no longer @unchecked Sendable; main-actor-affine documented | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| UI-002 | P0 | CodeEditorView | fixed | MarkedTextSession + applyMarkedText without undo registration | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-003 | P1 | CodeEditorView | fixed | AppKit internal drag uses moveText transaction; external size guard | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-004 | P1 | CodeEditorCore | fixed | WordNavigationMode codeSubword/camelCase/snake/acronym | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| UI-005 | P2 | CodeEditorView | fixed | EditorTextServicesPolicy code-editor defaults | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-006 | P1 | CodeEditorView | fixed | Layout max-width cache; invalidate on edit | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-007 | P1 | CodeEditorView | fixed | Virtualized accessibility value (viewport + line/col) | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-008 | P2 | CodeEditorView | fixed | EditorSignposts + EditorPerformanceHarness budgets | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| UI-009 | P0 | CodeEditorView | fixed | AppKit insertText honors replacementRange | Tests/CodeEditorViewTests/EditorControllerTests.swift, Tests/CodeEditorViewTests/NativeInputPhase3Tests.swift |
| WSP-003 | P0 | CodeEditorWorkspace | fixed | RelativeWorkspacePath + symlink/volume corpus | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| WSP-004 | P0 | CodeEditorWorkspace | fixed | FS actor + concurrent stress + cancel tests | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| WSP-005 | P1 | CodeEditorWorkspace | fixed | FSEvents recursive watcher with overflow/rescan + mock tests | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| WSP-006 | P0 | CodeEditorWorkspace | fixed | DocumentLeaseRegistry ref-count; final release unregisters | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| WSP-007 | P1 | CodeEditorWorkspace | fixed | On-disk golden fixtures v1/v999/corrupt; reject future schema | Tests/CodeEditorWorkspaceTests/WorkspaceTests.swift, Tests/CodeEditorWorkspaceTests/WorkspaceEditTransactionTests.swift |
| CMD-003 | P1 | CodeEditorCommands | fixed | CommandContextSnapshot from real focus/document/trust | Tests/CodeEditorCommandsTests/CommandSystemTests.swift, Tests/CodeEditorCommandsTests/Phase4CommandTests.swift |
| CMD-004 | P1 | CodeEditorCommands | fixed | Typed notFound/disabled/unsupported; palette-path executeAsync proof | Tests/CodeEditorCommandsTests/CommandSystemTests.swift, Tests/CodeEditorCommandsTests/Phase4CommandTests.swift |
| TER-002 | P0 | CodeEditorTerminal | fixed | ce_pty_spawn C helper; LocalPTYTransport exclusive FD; EAGAIN wait | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| TER-003 | P0 | CodeEditorTerminal | fixed | TerminalByteTransport ordered events; overflow fatal; no bufferingNewest drops | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| TER-004 | P0 | CodeEditorTerminalGhostty | fixed | GhosttySurfaceView/Representable; workbench uses Ghostty surface | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| TER-005 | P1 | CodeEditorTerminal | fixed | TerminalService create/write/close/closeAll/restoration config-only | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| TER-006 | P1 | CodeEditorDAP | fixed | GhosttyRunInTerminalHandler → TerminalService debuggee sessions | Tests/CodeEditorDAPTests/DAPSessionTests.swift, Tests/CodeEditorDAPTests/Phase7DAPTests.swift |
| TER-007 | P1 | CodeEditorTerminal | fixed | TerminalSecurityPolicy OSC52 deny; a11y adapter from Ghostty snapshot | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| TER-008 | P0 | CodeEditorTerminal | fixed | Workbench live path no longer feeds TerminalScreen; custom VT legacy/tests only | Tests/ReleaseTruthTests/ReleaseTruthTests.swift |
| LSP-004 | P1 | CodeEditorLSP | fixed | Ordered inbound notification/request chain | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-005 | P1 | CodeEditorLSP | fixed | negotiatedPositionEncoding stored on session | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-006 | P1 | CodeEditorLSP | fixed | Dynamic registration tracks methods | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-007 | P1 | CodeEditorLSP | fixed | applyEdit plan path (WorkspaceEditPlan) retained + tests | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-008 | P1 | CodeEditorLSP | fixed | LSPDiagnosticStore version-aware clear on empty/server | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| LSP-009 | P1 | CodeEditorLSP | fixed | scripts/check-real-lsp.sh hard when REQUIRE_REAL_LSP=1 | Tests/CodeEditorLSPTests/LSPClientTests.swift, Tests/CodeEditorLSPTests/Phase6ResidualTests.swift |
| TS-002 | P1 | CodeEditorTreeSitter | fixed | Generation-tagged highlights; stale discarded | Tests/CodeEditorTreeSitterTests/Phase6TreeSitterTests.swift |
| TASK-003 | P1 | CodeEditorTasks | fixed | Cancel waits process death; exclusive slot held until exit | Tests/CodeEditorTasksTests/TaskTests.swift, Tests/CodeEditorTasksTests/Phase7TaskTests.swift |
| TASK-004 | P1 | CodeEditorTasks | fixed | Bounded output single marker; unresolved vars throw | Tests/CodeEditorTasksTests/TaskTests.swift, Tests/CodeEditorTasksTests/Phase7TaskTests.swift |
| TASK-005 | P1 | CodeEditorTasks | fixed | FakeTaskRunner only in Tests/CodeEditorTasksTests | Tests/CodeEditorTasksTests/TaskTests.swift, Tests/CodeEditorTasksTests/Phase7TaskTests.swift |
| DAP-002 | P1 | CodeEditorDAP | fixed | Ordered inbound chain + lifecycle failed/terminated | Tests/CodeEditorDAPTests/DAPSessionTests.swift, Tests/CodeEditorDAPTests/Phase7DAPTests.swift |
| DAP-003 | P1 | CodeEditorDAP | fixed | runInTerminal Ghostty/TerminalService + trust deny | Tests/CodeEditorDAPTests/DAPSessionTests.swift, Tests/CodeEditorDAPTests/Phase7DAPTests.swift |
| SCM-002 | P1 | CodeEditorSourceControl | fixed | Trust-gated Git; per-op handles; component path check | Tests/CodeEditorSourceControlTests/SCMTests.swift, Tests/CodeEditorSourceControlTests/Phase7SCMTests.swift |
| PROC-001 | P1 | CodeEditorCore | fixed | ProcessSupervisor alias; tasks/Git share ProcessService | Tests/CodeEditorCoreTests/DocumentStoreTests.swift, Tests/CodeEditorCoreTests/UndoCoordinatorTests.swift |
| WB-007 | P1 | CodeEditorWorkbench | fixed | Problems/SCM/Debug models with unit tests | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| EXT-005 | P0 | CodeEditorExtensions | fixed | Corrupt durable state quarantines store | Tests/CodeEditorExtensionsTests/ExtensionRuntimeTests.swift, Tests/CodeEditorExtensionsTests/Phase8StoreSecurityTests.swift |
| EXT-006 | P0 | CodeEditorExtensions | fixed | SBOM/broker digests fail closed never length | Tests/CodeEditorExtensionsTests/ExtensionRuntimeTests.swift, Tests/CodeEditorExtensionsTests/Phase8StoreSecurityTests.swift |
| EXT-007 | P0 | CodeEditorExtensionHost | fixed | Reject symlink/special/key-material package entries | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-008 | P1 | CodeEditorExtensionAPI | fixed | TOML fail-closed api_version + unknown required fields | Tests/CodeEditorExtensionAPITests/ExtensionAPITests.swift |
| EXT-009 | P0 | CodeEditorExtensions | fixed | Recover re-verifies package generations | Tests/CodeEditorExtensionsTests/ExtensionRuntimeTests.swift, Tests/CodeEditorExtensionsTests/Phase8StoreSecurityTests.swift |
| EXT-010 | P1 | CodeEditorExtensionHost | fixed | Storage quota overwrite-correct + directoryKey keys | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-011 | P1 | CodeEditorExtensionHost | fixed | Durable settings under storage root | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-012 | P0 | CodeEditorExtensionHost | fixed | Streaming download mid-stream caps + redirect guard | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-013 | P0 | CodeEditorExtensionHost | fixed | Host-owned npm materializer no soft-stub | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-014 | P0 | CodeEditorExtensionHost | fixed | Process allowlist canonical/trusted-dir paths | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-015 | P1 | CodeEditorExtensionHost | fixed | Multi-root worktree + read limits + revoke | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| EXT-016 | P1 | CodeEditorExtensionHost | fixed | ExtensionSDKConformance kit | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| WASM-003 | P0 | CodeEditorWasmEngineWasmKit | fixed | Host imports read guest linear memory OOB-safe | Tests/CodeEditorWasmEngineTests/RealWasmExecutionTests.swift |
| WASM-004 | P0 | CodeEditorWasmEngineWasmKit | fixed | Wall-time + cooperative cancel interrupt | Tests/CodeEditorWasmEngineTests/RealWasmExecutionTests.swift |
| WASM-005 | P1 | CodeEditorWasmEngine | fixed | Memory limit/OOB enforcement | Tests/CodeEditorWasmEngineTests/WasmEngineTests.swift, Tests/CodeEditorWasmEngineTests/Phase9WasmExecutionTests.swift |
| WASM-006 | P0 | CodeEditorWasmEngineTests | fixed | Hostile fixture suite on WasmKit | Tests/CodeEditorWasmEngineTests/RealWasmExecutionTests.swift |
| WASM-007 | P1 | CodeEditorExtensionHost | fixed | Dual-run contract LinkedGuest vs WasmKit | Tests/CodeEditorExtensionHostTests/ExtensionHostTests.swift, Tests/CodeEditorExtensionHostTests/Phase8ExtensionSecurityTests.swift |
| WASM-008 | P1 | CodeEditorWasmEngine | fixed | Simulation alias = LinkedGuest; WasmKit is real | Tests/CodeEditorWasmEngineTests/WasmEngineTests.swift, Tests/CodeEditorWasmEngineTests/Phase9WasmExecutionTests.swift |
| WASM-009 | P1 | CodeEditorWasmEngine | fixed | Fixture gate script + session lifecycle | Tests/CodeEditorWasmEngineTests/WasmEngineTests.swift, Tests/CodeEditorWasmEngineTests/Phase9WasmExecutionTests.swift |
| WB-010 | P1 | CodeEditorWorkbench | fixed | Navigator set complete with models | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-011 | P1 | CodeEditorWorkbench | fixed | Tab pin/preview semantics + pane APIs | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-012 | P1 | CodeEditorWorkbench | fixed | Scheme/run destination + task routing | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-013 | P1 | CodeEditorWorkbench | fixed | Status LineIndex + activity cancel | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-014 | P1 | CodeEditorWorkbench | fixed | Chrome command ID matrix | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-015 | P1 | CodeEditorWorkbench | fixed | Open Quickly modes + path:line:col | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| WB-016 | P1 | CodeEditorWorkbench | fixed | FullWorkbench schemes/tasks/navigator wiring | Tests/CodeEditorWorkbenchTests/WorkbenchLogicTests.swift, Tests/CodeEditorWorkbenchTests/Phase16AccessibilityTests.swift |
| QUAL-001 | P1 | CI | fixed | Vacuous tests banned via check-vacuous-tests.sh | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-002 | P1 | CI | fixed | verify-stable.sh §26 master gate | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-003 | P1 | CI | fixed | check-release-evidence.sh validates JSON | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-004 | P1 | Docs | fixed | README/CompatibilityProfile honesty aligned Phases 7–10 | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, Docs/Architecture/PERF-BUDGETS.md |
| QUAL-005 | P1 | CI | fixed | API baselines refreshed; check-api-freeze | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-006 | P1 | CI | fixed | PERF-BUDGETS.md + check-perf-budgets.sh | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-007 | P1 | CI | fixed | Unchecked Sendable inventory + allowlist | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
| QUAL-008 | P1 | CI | fixed | Full swift test in verify-stable with counts | Tests/ReleaseTruthTests/ReleaseTruthTests.swift, .github/workflows/ci.yml |
