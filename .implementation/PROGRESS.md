# Audit Remediation Progress

**Program:** audit-2026-08-02-deep-remediation  
**Source:** `Docs/Architecture/AUDIT-2026-08-02-Deep-Audit-and-Stable-Plan.md`  
**Registry:** `Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json`  
**Policy:** TDD only · no skip · no defer · no residuals

## Status summary

| Phase | Name | Findings | Status |
|------:|------|---------:|--------|
| 0 | release-truth | 9 | fixed |
| 1 | documents | 12 | open |
| 2 | substrate | 3 (+ shared substrate build) | open |
| 3a | commands | 5 | open |
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

- 2026-08-02: Phase 0 release-truth — fixed PKG-N01, REL-N01…REL-N08 (honesty gates, CompatibilityProfile pre-alpha, evidence scorecards, defect regression links, a11y hierarchy, perf hard measurements, semantic API freeze, concurrency Werror, hard Ghostty/LSP/DAP; mocks moved to Tests/).
- 2026-08-02: bootstrap — audit plan + FINDINGS.json (174 open) + tracker present; `swift package dump-package` OK; `swift test --filter Nonexistent` builds (0 tests). All phases open; no findings marked fixed.
