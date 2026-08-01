# Product scorecards (Phase 16)

Machine-readable source: [`scorecards/products.toml`](scorecards/products.toml)

Checked by: `./scripts/check-product-scorecards.sh`

## Summary

All **26** public library products listed in `scripts/smoke-products.sh` (+ DAP) have scorecard rows against ADR-013 dimensions:

| Dimension | Meaning |
|---|---|
| api | Inventory + freeze policy |
| correctness | Phase evidence + tests |
| concurrency | Swift 6 package mode |
| tests | Suite coverage |
| platform | Capability profiles |
| operations | Recovery / store / soak |
| docs | DocC + guides |

**Zero residual policy:** every product has `residual = []`. See [DEFECTS.md](DEFECTS.md) (no open rows).

## How to re-score

1. Update `scorecards/products.toml` evidence strings.
2. Run `./scripts/check-product-scorecards.sh`.
3. Update this summary if product set changes.
