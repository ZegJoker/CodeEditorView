# Phase 11 notes — Stabilization and 1.0 qualification

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md`  
- Phase gate: **§ Phase 11**  
- Non-negotiable gates: **§26.1–26.9**  
- ADR: [ADR-013](ADR-013-stable-gate.md)

**Branch:** `remediation/audit-2026-08`  
**Policy:** Evidence-based qualification; no vacuous tests; **no soft-stubs**; no skip/defer.

> Prior `PHASE11-NOTES` described Swift-Wasm feasibility (pre-audit numbering). Wasm isolation is **Phase 9** / ADR-017. **Audit Phase 11 is stabilization.**

## Goal

Prove product-level stability with **executable** §26 gates rather than declaring Stable. Public README remains **pre-alpha** until a release owner consumes evidence and changes status.

## Master gate (hard)

```bash
./scripts/verify-stable.sh
```

Runs in order (all hard-fail):

1. product isolation, docs, feature profiles, scorecards, defects  
2. vacuous-tests ban, Xcode pin, API freeze  
3. wasm fixture, accessibility, security RC, licenses (full map)  
4. perf budgets, unchecked Sendable allowlist  
5. real LSP/DAP probes  
6. CodeEditorCore debug + release build  
7. **full `swift test`** with non-zero count  
8. ASan + TSan Core builds  
9. fuzz smoke (adversarial/malformed filters)  
10. soak smoke (multi-iteration Core+Documents)  
11. mutation smoke (isolated mutant must fail Core tests)  
12. generate + validate release evidence (`tests.exit_code==0`, `open_p0_p1==0`)  
13. source-archive clean-tree rehearsal  

## New / updated scripts

| Script | Role |
|---|---|
| `check-vacuous-tests.sh` | Ban `#expect(true)` / `\|\| true` / tautologies |
| `verify-stable.sh` | §26 master qualification gate (**hard**) |
| `check-release-evidence.sh` | Validate evidence JSON (must pass) |
| `check-perf-budgets.sh` | PERF-BUDGETS.md + optional measured sample |
| `check-unchecked-sendable.sh` | Allowlist for `@unchecked Sendable` |
| `generate-unchecked-sendable-inventory.sh` | Inventory doc |
| `run-sanitizers.sh` | ASan + TSan Core product builds |
| `run-fuzz-smoke.sh` | Adversarial/malformed test filter |
| `run-soak-smoke.sh` | Multi-iteration Core/Documents |
| `run-mutation-smoke.sh` | Isolated mutant must kill Core tests |

## Actions completed (audit Phase 11 list)

| Action | Evidence |
|---|---|
| Semantic API review + compatibility baselines | `Baselines/api/*` + `check-api-freeze.sh` |
| Full platform/toolchain matrix | `TOOLCHAIN.md`, `XCODE.pin`, `check-xcode-pin.sh` |
| Sanitizers, fuzzers, mutation, soak, perf, a11y, security | scripts + Phase11 tests + security-rc |
| Extension SDK author beta + migration rehearsals | `EXTENSION-AUTHORING.md`, `MIGRATION-1.0.md`, Phase16 migration tests in full suite |
| Release-source/archive rehearsal | `export-source-archive-rehearsal.sh` (hard) |
| Docs verified from actual behavior | honesty README/profile; DocC/docs checks |
| Remove deprecated/fake compatibility layers | vacuous ban; soft `\|\| true` removed from verify-stable |

## Gate evidence map (§26)

| # | Proof |
|---|---|
| E1 | `check-defects.sh` — zero open P0/P1 |
| E2 | `export-source-archive-rehearsal.sh` |
| E3 | `check-xcode-pin.sh` / TOOLCHAIN.md |
| E4 | `swift build` debug+release Core |
| E5–E6 | full `swift test` + vacuous ban |
| E7 | `check-real-lsp.sh` / `check-real-dap.sh` |
| E8–E9 | security-rc, isolation, profiles, scorecards, licenses |
| E10 | `Baselines/api` + `check-api-freeze.sh` |
| E11 | generate + check-release-evidence |
| E12 | accessibility + `Phase11QualificationTests` |
| E13 | `PERF-BUDGETS.md` + `Phase11PerfSmokeTests` |
| E14 | `UNCHECKED-SENDABLE.md` + allowlist |
| E15–E16 | README/profile honesty + check-docs |
| E17 | sanitizer / fuzz / soak / mutation hard smokes |
| E18 | this file + QUAL-001…008 fixed |

## Full suite proof (this phase)

```
swift test  →  834 tests in 242 suites passed
```

Stability fixes required for that green run (not soft-skipped):

- Tree-sitter `fullParse` **awaits** off-main engine `setText` (fire-and-forget left `queryHighlights` empty under race).
- MCP JSON-RPC **register-before-send + early-response buffer** (send-first / register-race left never-resumed continuations and hung full suite after language-switch suites; regression: `rapidSequentialSessionsDoNotHang`).
- Debug language-switch dump test rewritten to bounded assertions (no infinite layout dump).

## Qualification claim (honest)

Phase 11 produces **machine evidence** that §26-style gates pass under this repository’s supported pin (Xcode 26.4 / Swift 6.3 / macOS arm64 host). It does **not** auto-publish marketing “1.0 GA / all products Stable”. Release owners must still decide status using evidence + product scorecards.

## Defects

QUAL-001…008 closed as **fixed** in `DEFECTS.md` / `defects.json`.

## Related

- Phases 1–10 remediation foundations  
- ADR-013 evidence-based Stable gate  
- Phase 16 RC residual tooling (`verify-rc.sh` still available; delegates vacuous/perf/unchecked hooks)  
