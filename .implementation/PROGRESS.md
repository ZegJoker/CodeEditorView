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
| 3a | commands | 5 | fixed |
| 3b | native editor UI | 10 | open |
| 4 | workspace | 10 | open |
| 5a | search | 9 | open |
| 5b | tasks | 8 | open |
| 5c | SCM | 9 | open |
| 6a | language/Tree-sitter | 7 | open |
| 6b | LSP | 13 | open |
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
