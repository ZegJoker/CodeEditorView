# Audit Remediation Progress

**Program:** audit-2026-08-02-deep-remediation  
**Source:** `Docs/Architecture/AUDIT-2026-08-02-Deep-Audit-and-Stable-Plan.md`  
**Registry:** `Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json`  
**Policy:** TDD only · no skip · no defer · no residuals

## Status summary

| Phase | Name | Findings | Status |
|------:|------|---------:|--------|
| 0 | release-truth | 9 | verified |
| 1 | documents | 12 | verified |
| 2 | substrate | 3 (+ shared substrate build) | verified |
| 3a | commands | 5 | verified |
| 3b | native editor UI | 10 | verified |
| 4 | workspace | 10 | verified |
| 5a | search | 9 | verified |
| 5b | tasks | 8 | verified |
| 5c | SCM | 9 | verified |
| 6a | language/Tree-sitter | 7 | verified |
| 6b | LSP | 13 | fixed |
| 7 | DAP | 10 | open |
| 8 | terminal/Ghostty | 10 | open |
| 9a | extension package/signing | 20 | open |
| 9b | capability broker | 16 | open |
| 9c | Wasm | 16 | open |
| 10 | workbench | 7 | open |
| F | final residual gate | all 174 | open |

## Rules for implementers

1. Read the finding section in the audit doc by ID before coding.
2. Write failing regression tests first (name includes finding ID, e.g. `test_DOC_N01_...`).
3. Implement until tests pass; never mark fixed without green tests.
4. Update `AUDIT-2026-08-02-FINDINGS.json`: `status` → `fixed`, list `regression_tests`.
5. No `XCTSkip`, no `#if false` test bodies, no `TODO` production stubs, no soft production fallbacks for security/data-loss paths.
6. Prefer shared substrate (`AsyncBroadcastHub`, `OneShotPromise`, `ProcessSupervisor`, `FramedRPCConnection`) over product-local copies.
7. Commit after each finding or tight related group with message including finding IDs.

## Log

- 2026-08-03: Phase 6b LSP verifier residual (2) — removed `LanguageServerSession.text(for:)` soft empty fallback entirely (requireText only; digester/symbol baselines updated); N12 hard-requires AsyncBroadcastHub stream delivery of versioned diagnostics (no `latestPublication` soft-OR); N13 requires literal `full session` success when sourcekit-lsp/clangd present (binary-name-only OK rejected). CodeEditorLSPTests 60 passed.

- 2026-08-03: Phase 6b LSP verifier residual — LSP-N09 navigation/workspace-symbol use `requireText` fail-closed (removed production `session.text(for:)` empty soft path); hardened N04 (incremental vs forceFull, gap reopen text), N06 (didChange before didSave hard), N13 (executes check-real-lsp.sh + in-process session steps); cleared LSP residuals from scorecard inventory. CodeEditorLSPTests green.

- 2026-08-03: Phase 6b LSP — fixed LSP-N01…LSP-N13: OneShotPromise pending-before-send (no earlyResponses/unstructured Task); inbound message lanes (response/state-ordered/independent/server-request); safe `synchronize(from:applying:to:)`; capability+policy sync (preferIncremental/forceFull/none) with version-gap full resync; per-document `LSPDocumentLane` (save flushes change, close barrier); open state after successful send; complete WorkspaceEdit (changes/documentChanges/resource ops/annotations → WorkspaceEdit); snapshot miss fail-closed; registration-by-id; JSONValue; versioned bounded diagnostics via AsyncBroadcastHub; check-real-lsp.sh full fixture + Tests/Fixtures/LSP. CodeEditorLSPTests 57 passed.

- 2026-08-03: batch language-tree-sitter verified — LANG-N01, LANG-N02, LANG-N03, LANG-N04, LANG-N05, LANG-N06, LANG-N07 status set to `verified` (all previously fixed with regression tests; LANG filter green, residual closed).
- 2026-08-03: Phase 6a language/Tree-sitter verifier residual (2) — hard tests: LANG-N05 `EngineError.cancelled` fail-closed + document/language generation stale discard; LANG-N06 malformed fixture in-range + recovery to real JSON scopes; LANG-N07 explicit init generation==0 + host isolation from shared (no vacuous expects). ParseSession/TreeSitterHighlightProvider map cancel to typed error. LANG filter 41 passed.
- 2026-08-03: Phase 6a language/Tree-sitter verifier residual — LANG-N02/N04/N05: `CodeEditorTreeSitterTests` links real `TreeSitterJsonGrammar`/`CodeEditorLanguageJSON`; `QuerySetLoader.compile`/`loadAndCompile` fail-closed (removed `loadSourcesSoft`); N02 factory/malformed tests assert typed throws with real grammar pointer (no `#expect(Bool(true))`); N03/N04/N05 configure real `LanguageConfiguration` + `TSLanguageRef` retention across edits/stress; N05 capture scopes + large-file real tree; N06 expected scopes + present optional queries must compile; pin-aligned perl/verilog/markdown-inline queries. LANG filter 41 passed; TreeSitter+Languages+Support 70 passed.
- 2026-08-03: Phase 6a language/Tree-sitter — fixed LANG-N01…LANG-N07: `LanguageRegistrationRecord` owner/generation/priority/token (dispose removes only that record); malformed present queries fail closed (`QuerySetError` / no silent `try?`); single `ParseSession` actor path (`LanguageDocumentActor` typealias; highlight provider no dual main-actor tree); `TSLanguageRef` ownership wrappers + stress; expanded CodeEditorTreeSitterTests; 39-grammar conformance matrix; host-owned `bootstrap(into:)` registries. Language product suites + View Tree-sitter filters green.
- 2026-08-03: batch scm verified — SCM-N01, SCM-N02, SCM-N03, SCM-N04, SCM-N05, SCM-N06, SCM-N07, SCM-N08, SCM-N09 status set to `verified` (all previously fixed with regression tests; CodeEditorSourceControlTests SCMN green, residual closed).
- 2026-08-03: Phase 5c SCM verifier residual — SCM-N06 fail-closed `documentCoordinatorRequired` (service + provider discard/discardHunk/checkout/pull; no soft nil return); FullWorkbench HostServices binds `DocumentLifecycleCoordinator` + `startStatusWatching`; SCM-N03 fraction progress + cancel kills ProcessHandle; SCM-N08 watcher-driven debounced stale→fresh refresh; strengthened N02 askpass runtime, N07 required quotes, N09 runtime ProcessSupervisor spawn bounds. CodeEditorSourceControlTests 46 passed.
- 2026-08-03: Phase 5c SCM — fixed SCM-N01…SCM-N09: per-repo `SCMRepositoryIdentity` (not constant `git`); auth callback + GIT_ASKPASS fail-closed + `SCMLogSanitizer`; progress via AsyncBroadcastHub + `SCMRepositoryGate`; dual index/worktree `SCMFileStatus`; exclusive mutations; destructive ops preflight via `SCMDocumentCoordinator`/`DocumentLifecycleCoordinator`; git-validated hunk patches (`apply --check`); multicast status snapshots with finish on provider removal; `ProcessSupervisor` + bounded stdout/stderr. CodeEditorSourceControlTests 41 passed.
- 2026-08-03: batch tasks verified — TASK-N01, TASK-N02, TASK-N03, TASK-N04, TASK-N05, TASK-N06, TASK-N07, TASK-N08 status set to `verified` (all previously fixed with regression tests; CodeEditorTasksTests TASKN green).
- 2026-08-03: Phase 5b verifier residual — TASK-N01 runtime hub replay + equal consumer counts; TASK-N03 BoundedByteSpool absolute-offset viewport reads (baseOffset/totalAppendedBytes/read); TASK-N06 exclusiveGroupLastOutcome records holder failure (no empty catch), executeGraph terminal-only outcomes (live ≠ succeeded), start() live root without provisional success, hard skippedBecauseDependency/notReady asserts. CodeEditorTasksTests 50 passed; N03 core viewport green.
- 2026-08-03: Phase 5b tasks — fixed TASK-N01…TASK-N08: TaskExecutionHandle on AsyncBroadcastHub (multicast); IncrementalUTF8Decoder per stream + raw spool; BoundedByteSpool + single truncation marker; maxCollectedBytes clamp; validated readiness regex (fail closed); TaskNodeOutcome/executeGraph DAG; component path normalize + VersionedProblemRange; hub/channel finish ownership on exit/cancel. CodeEditorTasksTests 48 passed.
- 2026-08-03: batch search verified — SRCH-N01, SRCH-N02, SRCH-N03, SRCH-N04, SRCH-N05, SRCH-N06, SRCH-N07, SRCH-N08, SRCH-N09 status set to `verified` (all previously fixed with regression tests; CodeEditorSearchTests SRCHN green, 25 passed).
- 2026-08-03: Phase 5a search — fixed SRCH-N01…SRCH-N09: nested `.gitignore` discovery (no skipsHiddenFiles); git-compatible ignore corpus vs `git check-ignore`; separate WorkspaceGlobPattern grammar; bounded worker pool + cancellation; DocumentCodec encoding skip reporting; per-file match/size/time budgets; SearchCompletionMetrics (scanned ≠ matched); full regex replace (`$n`, `${name}`, `$$`, zero-width, exact ranges); snapshot-bound pin/commit multi-file replace. CodeEditorSearchTests 39 passed.
- 2026-08-03: batch workspace verified — WSP-N01, WSP-N02, WSP-N03, WSP-N04, WSP-N05, WSP-N06, WSP-N07, WSP-N08, WSP-N09, WSP-N10 status set to `verified` (all previously fixed with regression tests; CodeEditorWorkspaceTests WSPNAudit green).
- 2026-08-03: Phase 4 workspace verifier residual — WSP-N01/N06: canonical journal checksum (JSONEncoder.sortedKeys + millisecondsSince1970) so encode→decode→recompute matches; recoverPendingTransactions on Workspace.activate()/local(); recovery must yield rolledBack not quarantine for valid prepared journals; strengthened N01/N03/N04/N08/N10 tests (no .quarantined accept, no vacuous Bool(true)/listCount OR, package-scoped DocumentRegistry mutations). CodeEditorWorkspaceTests 81 passed; N06 isolated 5× green.
- 2026-08-03: Phase 4 workspace — fixed WSP-N01…WSP-N10: WorkspaceTransactionCoordinator (prepare/commit/recover, one rollback owner, undo only on success); dirty-descendant delete preflight + trash staging; bulk close decision→save→commit (all-or-nothing default); FS workers with batch streaming + progress hub; honest WorkspaceArchive (symlink no-follow, no false full-POSIX claim); durable journal checksum/quarantine/startup recovery; workspaceEvents snapshot+sequence; DescriptorRelativeIO openat/unlinkat/renameat O_NOFOLLOW; host WorkspaceHiddenFilePolicy; DocumentLifecycleCoordinator sole registry mutator. CodeEditorWorkspaceTests 78 passed.
- 2026-08-03: batch native-editor-ui verified — UI-N01, UI-N02, UI-N03, UI-N04, UI-N05, UI-N06, UI-N07, UI-N08, UI-N09, UI-N10 status set to `verified` (all previously fixed with regression tests; CodeEditorViewTests UINAudit green).
- 2026-08-03: Phase 3b verifier residual — UI-N01 host `visualCaretMove`/AppKit moveDown; UI-N04 CoreText CTLine platform BiDi; UI-N08 real macOS+iOS sim builds + platform-matrix.json evidence (xcodebuild hosts under CI); UI-N09 enforce highlighter suspend/diagnostics reject/bounded undo + auto-refresh; UI-N10 AppKit/UIKit custom rotors, live breakpoints/symbols, completion announcements, chrome landmarks, system reduce-motion. CodeEditorViewTests UIN0+UIN10: 45 passed.
- 2026-08-02: Phase 3b native editor UI — fixed UI-N01…UI-N10: CaretNavigationEngine + layout snapshots; grapheme-valid positions; fragment selection geometry; WritingDirectionModel BiDi; firstRect/attributedSubstring contracts; IME begin/cancel/commit lifecycle; EditorDiagnosticChannel (no silent try? on input); PLATFORM-MATRIX + check-platform-matrix.sh; LargeFileMode explicit limitations; semantic accessibility (line/col, rotor, multi-cursor, completion, landmarks, reduced motion). CodeEditorViewTests UINAudit 36 passed.
- 2026-08-02: batch commands verified — CMD-N01, CMD-N02, CMD-N03, CMD-N04, CMD-N05 status set to `verified` (all previously fixed with regression tests; CodeEditorCommandsTests green).
- 2026-08-02: Phase 3a commands — fixed CMD-N01…CMD-N05: rejectDuplicate registration + owned replace with diagnostics; CommandID lowercase grammar + reserved `codeeditor` namespace; explicit synchronous dispose (no deinit Task); chord timeout re-resolves live context/focus scope and surfaces errors; CommandExecutionClass gates long-running off sync MainActor. CodeEditorCommandsTests 45 passed; Search/Tasks/SCM/Extensions/Workbench subset green.
- 2026-08-02: batch substrate verified — CORE-N02, CORE-N03, CORE-N04 status set to `verified` (all previously fixed with regression tests; ProcessSubstrate+Broadcast+Promise/RPC green).
- 2026-08-02: Phase 2 verifier residual — CORE-N02/N03/N04: removed tautology/Bool(true) expects; cancel asserts elapsed<50ms + exit.code!=0; non-macOS #else asserts unavailableOnPlatform; shell deny throws ProcessServiceError.shellCapabilityRequired; non-macOS ProcessHandle documented fail-closed already-terminated. ProcessSubstrate+Broadcast+Promise/RPC: 16 passed; Core+Tasks: 117 passed.
- 2026-08-02: Phase 2 substrate — fixed CORE-N02/N03/N04 + shared substrate (§22): AsyncBroadcastHub (sequence/gap/replay/finish), OneShotPromise + DeadlineScheduler/TestDeadlineClock, BoundedByteSpool, FramedRPCConnection (Content-Length + JSON-RPC codec), ProcessSupervisor actor. ProcessHandle multi-subscriber bounded events; cancel() nonblocking + awaitTermination; shell via localShellExecution. CodeEditorCoreTests+Tasks+SCM: 136 passed.
- 2026-08-02: batch documents verified — DOC-N01…DOC-N11 + CORE-N01 status set to `verified` (all previously fixed with regression tests).
- 2026-08-02: Phase 1 verifier residual (2) — DOC-N09 per-call peak retained payload (single buffer ≤N; hash-only ≤chunk); DOC-N10 beforeParentFsync pins disk==NEW (no soft ORIG); DOC-N05 overflow-safe residuals in TextRange/MultiRangeEdit/Search/LSP/LanguageServiceSanitize with adapter tests. 28 DOC-N/CORE-N01 + 190 product-suite tests pass.
- 2026-08-02: Phase 1 verifier residual — strengthened weak tests: DOC-N06 drain+streamGap on overflow; DOC-N10 parentDirectoryFsyncObserver asserts real fsyncDirectory; CORE-N01 off-main assertOwnership violation probe; DOC-N04 atomic group DocumentStore.apply (no intentional partial mutation). 24 DOC-N/CORE-N01 tests pass.
- 2026-08-02: Phase 1 documents — fixed DOC-N01…DOC-N11 + CORE-N01 (content-state savepoints, DocumentSaveRequest CAS API, equal-offset declaration order, atomic undo only, overflow-safe ranges, bounded sequenced events, encoding fail-closed, coordinated identity write, single-buffer/hash-only read, parent fsync durable write, versioned recovery record, DocumentStore main-actor ownership). CodeEditorCoreTests+CodeEditorDocumentsTests: 114 passed.
- 2026-08-02: batch release-truth verified — PKG-N01, REL-N01…REL-N08 status set to `verified` (all previously fixed with regression tests).
- 2026-08-02: Phase 0 verifier residual close — REL-N04 live AppKit AX probe (NSHostingController + WorkbenchAccessibilityNSAnchorView; no hardcoded chrome catalog) + Switch Control fail-closed throws with real API invocation; PKG-N01 always executes ARCHIVE_PHASE=smoke clean archive path (CI full suite via FULL_ARCHIVE_TEST=1); 39 Phase-0 regression tests pass.
- 2026-08-02: Phase 0 REL-N06 — regenerated digester/symbol-graph baselines after MockRemoteTerminalTransport left production (API freeze green; 38 Phase-0 regression tests pass).
- 2026-08-02: Phase 0 verifier rework — PKG-N01 hard suite exit + no soft --version; REL-N02 generate-product-scorecards evidence; REL-N04 content-sourced a11y + fail-closed Switch Control; REL-N05 DocumentStore/LineIndex fixed datasets; REL-N06 real digester/symbol-graph (no public seed); REL-N08 DAP post-init responses + DAPTestTransport/MockRemote moved to Tests/.

- 2026-08-02: Phase 0 verifier remediation — PKG-N01 full-archive default + execution test; REL-N01 CI generate-compatibility-profile; REL-N04 WorkbenchAccessibilitySession keyboard/rotor/Switch Control; REL-N05 p50/p95/p99+memory/cpu/allocs producer; REL-N06 digester/symbol-graph freeze; REL-N07 TSan executes tests + per-site dossier; REL-N08 production requireLinked/requireGhosttyLinked defaults true.
- 2026-08-02: Phase 0 release-truth — fixed PKG-N01, REL-N01…REL-N08 (honesty gates, CompatibilityProfile pre-alpha, evidence scorecards, defect regression links, a11y hierarchy, perf hard measurements, semantic API freeze, concurrency Werror, hard Ghostty/LSP/DAP; mocks moved to Tests/).
- 2026-08-02: bootstrap — audit plan + FINDINGS.json (174 open) + tracker present; `swift package dump-package` OK; `swift test --filter Nonexistent` builds (0 tests). All phases open; no findings marked fixed.
