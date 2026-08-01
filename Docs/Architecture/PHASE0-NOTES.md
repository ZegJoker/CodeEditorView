# Phase 0 notes — Program baseline and decisions

## Goal

Make the stabilization + Swift-first extension program measurable and buildable; lock architectural decisions so later phases do not thrash.

## Environment (local reference baseline)

| Item | Value |
|---|---|
| Date (UTC) | 2026-07-31 |
| Host | macOS 26.5.2 (Build 25F84), arm64 |
| Swift | Apple Swift 6.3 (`swift-driver` 1.148.6, swiftlang-6.3.0.123.5) |
| Package platforms | iOS 18+, macOS 15+ |
| CI | None yet (Phase 1) |

Formal CI reference hardware is deferred to Phase 1.

## Clean-build reproduction

1. Clone repository.
2. `./scripts/update-grammars.sh` (requires git + network; populates gitignored `Grammars/`).
3. `swift package resolve`
4. `swift test`
5. `./scripts/check-product-isolation.sh`
6. `./scripts/check-docs.sh`

Optional symbol-graph dump (API inventory helper): `./scripts/dump-symbol-graphs.sh`

### Grammar packaging fixes (Phase 0)

`scripts/update-grammars.sh` was incomplete for current upstream layouts:

| Issue | Fix |
|---|---|
| Missing sibling headers (e.g. Haskell `unicode.h`) | Copy `*.h` / `*.hpp` / `*.inc` from grammar `src/` |
| Relative `#include "../../common/…"` after flatten (TS/TSX/PHP/OCaml) | Rewrite includes to `"common/…"` after copying `common/` |

**Note:** `scripts/grammars.tsv` still pins mutable branches (`main`/`master`). Immutable SHA + checksum pins are Phase 1 start / Phase 4 completion.

## Baseline measurements (2026-07-31)

| Check | Result |
|---|---|
| `swift package resolve` | OK |
| `swift test` | **359 tests / 101 suites — all passed** (~11s after grammar compile) |
| `scripts/check-product-isolation.sh` | OK |
| `scripts/check-docs.sh` | OK (after Phase 0 docs) |
| `@unchecked Sendable` occurrences (Sources) | **45** |
| Direct `Process()` sites | LSP, Tasks, Terminal, SCM, ExtensionHost (5 products) — no platform fail-closed yet |
| Public-ish decls in Extensions+Host (rough `public ` rg count) | **~390** lines |
| Extension manifest | `extension.json` only |
| Extension author product | Not split (`CodeEditorExtensionAPI` Phase 9) |

Compile warnings observed (non-blocking for Phase 0):

- `EditorController.documentObservationTask`: `nonisolated(unsafe)` no-effect suggestion
- `DocumentViewProvider.platformImage`: ViewBuilder + explicit `return`

## Decisions landed

| Artifact | Purpose |
|---|---|
| [ADR-013](ADR-013-stable-gate.md) | Evidence-based Stable gate |
| [ADR-014](ADR-014-swift-first-extensions.md) | Swift-first extension platform; CodeEditor-owned package/runtime contracts |
| [ADR-015](ADR-015-extension-threat-model.md) | Runtime trust + fail-closed authority model |
| [ADR-016](ADR-016-platform-profiles.md) | Direct-macOS / MAS / iOS / enterprise / test profiles |
| [CompatibilityProfile.toml](CompatibilityProfile.toml) | Scaffold profile (all features experimental/pending) |
| [PRODUCT-OWNERS.md](PRODUCT-OWNERS.md) | Product ownership map |
| [EXTENSION-API-INVENTORY.md](EXTENSION-API-INVENTORY.md) | Types for Phase 9 author-API extraction |

Plan defaults applied without further debate:

- Four runtimes: built-in, data-only, native-process (trusted-only), Swift-Wasm
- Native helpers = reliability boundary, not sandbox
- iOS: no downloadable native code; process-backed features must fail closed
- S0–S4 first stable (CodeEditor package/runtime levels)

## Program rules (gate)

Effective immediately for this program:

1. Public feature merges need: owner (or acting PR author), platform contract note, test plan, stability classification.
2. Each phase stops at its documented gate before the next starts.
3. Product isolation and docs inventory remain green.

## Open items deferred

| Item | Phase |
|---|---|
| GitHub Actions CI matrix | 1 |
| `PlatformCapabilityProfile` + `CodeEditorPlatformError` | 1 |
| Guard every `Process()` behind platform profile | 1 |
| Immutable grammar pins + checksums | 1–4 |
| Symbol-graph CI baselines | 1 |
| Core/Documents safety | 2 |
| `CodeEditorExtensionAPI` + `extension.toml` | 9 |
| Native process / Wasm drivers | 10–11 |

## Exit criteria

- [x] Package builds after grammar generation
- [x] `swift test` baseline recorded (359/359 pass)
- [x] Isolation + docs scripts green
- [x] ADR-013…016 landed
- [x] CompatibilityProfile.toml scaffold
- [x] PRODUCT-OWNERS.md
- [x] EXTENSION-API-INVENTORY.md
- [x] PHASE0-NOTES.md (this file)
- [x] Grammar bootstrap script fixed for current upstreams

**Phase 0 gate: PASS** — ready for Phase 1 (CI, platform contracts, reproducibility).
