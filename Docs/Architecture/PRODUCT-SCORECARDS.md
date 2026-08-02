# Product scorecards

Machine-readable source: [`scorecards/products.toml`](scorecards/products.toml)

Checked by: `./scripts/check-product-scorecards.sh` (REL-N02)

## Policy

- `certification = "pre-alpha"`: dimensions may be `fail`/`unproven`; **residual must be non-empty** when any dimension is non-pass.
- `status = "pass"` requires a real filesystem **artifact** path (not prose alone).
- `RELEASE_CERTIFY=1` rejects any non-pass, residual, or open P0/P1.
- Product set includes all public libraries plus `CodeEditorTerminalGhostty`, `codeeditor-extension`, and `ConformanceExtensionGuest`.

## Dimensions

| Dimension | Meaning |
|---|---|
| api | Inventory + freeze evidence |
| correctness | Tests / audit residuals |
| concurrency | Swift 6 / unchecked dossier |
| tests | Suite coverage evidence |
| platform | Toolchain / profile evidence |
| operations | Recovery / store / soak evidence |
| docs | DocC + guides |

Do not claim residual-empty release readiness while dimensions fail.
