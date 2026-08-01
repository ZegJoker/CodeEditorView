# Defect register (Phase 16 RC)

Severity: **P0** (ship-blocker data loss / security bypass) · **P1** (major broken feature without workaround) · **P2** (significant limitation) · **P3** (minor / docs)

Gate rule: **no open defects of any severity** (`./scripts/check-defects.sh`).

| ID | Severity | Product | Status | Notes |
|---|---|---|---|---|
| P16-001 | P2 | CodeEditorWasmEngine | closed | Host ABI v1 promoted Stable (ADR-017 revision); WasmKit + fixture gates |
| P16-002 | P2 | CodeEditorExtensionWasmGuest | closed | Same Wasm host contract promotion; dual-run evidence Phase 11/16 |
| P16-003 | P3 | CodeEditorExtensionAPI | closed | Slash commands promoted to stable (profile + defaults + host tests) |
| P16-004 | P3 | CodeEditorExtensionHost | closed | Remote provider promoted to stable; residual closure host tests |
| P16-005 | P3 | CodeEditorLSP | closed | Claimed method matrix documented + Phase16LSPMatrixTests |
| P16-006 | P3 | docs | closed | RC docs pack (PHASE16-NOTES, CONFORMANCE-REPORT, scorecards) |

## Process

1. New defects must start as `open` with severity and product.
2. Closing a defect: set Status `closed` and evidence note.
3. Do not remove historical rows; append.
4. `check-defects.sh` fails if **any** row is `open`.
