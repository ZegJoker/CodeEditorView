# Phase 16 notes — Release candidates and stabilization

## Goal

RC readiness: API freeze, product scorecards, S0–S4 conformance report, migration/rollback rehearsals, performance/accessibility/security/soak gates, docs/examples — **no open P0/P1**, no soft-stubs.

## Deliverables

| Item | Location |
|---|---|
| API freeze inventories | `Baselines/api/*.public.txt` |
| Freeze checker | `scripts/check-api-freeze.sh` |
| Product scorecards | `scorecards/products.toml`, PRODUCT-SCORECARDS.md |
| Defect register | DEFECTS.md |
| Conformance report | CONFORMANCE-REPORT.md |
| Security pack | SECURITY-RC.md |
| RC checklist | Docs/Guides/RC-CHECKLIST.md |
| Master gate | `scripts/verify-rc.sh` |
| Tests | `Phase16*` suites |

## Gate commands

```bash
./scripts/verify-rc.sh
swift test --filter Phase16
./scripts/generate-conformance-report.sh   # optional long run
```

## Soft-stub ban

| Forbidden | Actual |
|---|---|
| Scorecard pass without evidence | TOML evidence fields + checker |
| Fake S-level claims without tests | Report + CompatibilityProfile |
| Freeze without baseline | Diff against Baselines/api |
| Soak N=1 | ≥20 iterations |
| Perf always-true | Budget compare in tests |

## Residuals

**None open.** All P16-001…006 closed (Wasm host ABI stable, slash/remote stable, LSP claimed matrix, docs).
