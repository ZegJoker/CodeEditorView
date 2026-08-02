# Phase 7 notes — Tasks, builds, diagnostics, DAP, and SCM

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md`  
- Phase gate: **§ Phase 7**  
- DAP: **§14.1–14.8**  
- Tasks/process/matchers: **§18.1–18.12**  
- SCM: **§19.1–19.8**  

**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD residual completion; no soft-stubs; no fabricated offsets.

> Terminal / Ghostty / PTY work is **Phase 5** (TER-*). This document no longer claims VT/forkpty as Phase 7 deliverables.

## Goal

Shared process supervision; snapshot-accurate problem matchers; deterministic task graph/cancel/output/variables; race-free ordered DAP with real `runInTerminal`; trust-gated Git with porcelain fixtures and concurrent ops; workbench problems/SCM/debug models.

## Deliverables

| Item | Status |
|---|---|
| `ProcessSupervisor` (`= ProcessService`) shared by tasks + Git | Done |
| Process cancel waits for death before exclusive release | Done |
| Snapshot-only diagnostic ranges (`MatchedProblem.resolvedRange`) | Done |
| Streaming/multiline matchers + chunk-split + EOF flush | Done |
| Dep graph: failed-before-ready never unblocks | Done |
| Bounded `OutputChannel` with **one** truncation marker | Done |
| Unresolved `${var}` throws `TaskError.invalidDefinition` | Done |
| `FakeTaskRunner` only under `Tests/CodeEditorTasksTests` | Done |
| DAP register-before-send + ordered inbound chain | Done |
| DAP lifecycle: start failure → `.failed`; event-driven states | Done |
| `DAPTCPConnectTransport` for `.connect` launch | Done |
| `runInTerminal` → Ghostty/`TerminalService`; untrusted deny | Done |
| Git porcelain fixtures (rename dest, unicode, conflict, copy) | Done |
| Component-aware path containment; sibling repo reject | Done |
| Trust default fail-closed; per-operation process handles | Done |
| Workbench problems / SCM / debug session models | Done |
| `scripts/check-real-dap.sh` soft / hard when `REQUIRE_REAL_DAP=1` | Done |

## Gate evidence

```text
swift test --filter 'Phase7|CodeEditorTasksTests|CodeEditorDAPTests|CodeEditorSourceControlTests|Phase5DAP'
# 63 tests / 9 suites — all passed

./scripts/check-defects.sh
# OK (no open/partial P0/P1)

./scripts/check-real-dap.sh
# soft OK without adapter; hard when REQUIRE_REAL_DAP=1
```

### Exit criteria map

| # | Criterion | Proof |
|---|---|---|
| E1 | ProcessSupervisor + cancel-wait | `processSupervisorAliasExists`, `cancelExclusiveWaitsForProcessDeath` |
| E2 | Snapshot line/col ranges | `snapshotResolveExactLineColumn`, `neverFabricatesLineTimesColumnOffsets` |
| E3 | Chunk/multiline matchers | `streamingMatcherAcrossChunkBoundary`, `multilineMatcherEOFFlush` |
| E4 | Dependency DAG fail-closed | `dependencyFailedBeforeReady` |
| E5 | Cancel exclusivity | `cancelExclusiveWaitsForProcessDeath` |
| E6 | Output bounds | `outputChannelTruncatesOnce` |
| E7 | Variables fail-closed | `unresolvedVariableThrows` |
| E8 | No prod FakeTaskRunner | `fakeTaskRunnerNotInProductionSources` |
| E9 | DAP register + order | `registerBeforeSendInstantReply`, `inboundEventsPreserveOrder` |
| E10 | DAP lifecycle | `startFailureLeavesFailedState`, `sessionLifecycleStoppedContinuedTerminated` |
| E11 | runInTerminal | `runInTerminalCreatesDebuggeeSession`, `runInTerminalDeniedWhenUntrusted`, `runInTerminalReverseUsesHandler` |
| E12 | Porcelain fixtures | `porcelainZRenameUsesDestinationPath`, unicode/conflict/copy |
| E13 | Path + trust | `siblingRepoPathRejected`, `untrustedGitStatusFailsClosed` |
| E14 | Concurrent SCM | `concurrentOpsDoNotCrossCancel` |
| E15 | Workbench models | `taskProblemsBridgeIngestsMatched`, `debugModelTracksSessions`, `scmModelFailsClosedWhenUntrusted` |
| E16 | Docs + defects | This file; TASK/DAP/SCM/PROC/WB closed |

## Forbidden residuals (verified absent)

- `line * 200 + column` fabricated offsets in `Sources/CodeEditorTasks`
- `FakeTaskRunner` in production product
- DAP send-before-register (register-before-send path)
- Unbounded output without truncation policy
- Empty variable substitution for unresolved names
- Git rename using source as primary path
- String `hasPrefix`-only path security for repo roots

## Residual vs deeper product work

- Full debugger UI (memory/disassembly/inline values) is out of Phase 7 — models only  
- Live `lldb-dap` CI is optional hard gate via `REQUIRE_REAL_DAP=1`  
- libgit2 provider remains protocol-ready; CLI is the macOS path  

## Defects closed

TASK-001…005, DAP-001…003, SCM-001…002, PROC-001, WB-007.

## Related

- Phase 5 Ghostty terminal + TER-006 runInTerminal path  
- Phase 6 LSP register-before-send / ordered inbound (mirrored for DAP)  
- Phase 8 workbench deep integration / extensions  
