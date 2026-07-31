# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with stability tiers described in `Docs/Guides/API-STABILITY.md`.

## Unreleased

### Added

- Phase 7: `ProcessService` with process-group kill, streaming I/O, timeouts, shell quoting
- Phase 7: Task execution handles, concurrency groups, readiness matchers, streaming problem matchers
- Phase 7: VT parser/screen model, macOS PTY backend, remote terminal transport contract
- Phase 7: Git `-z` status, discovery, full SCM mutations, path safety, trust/cancel
- Phase 7: CI tooling matrix job; `PHASE7-NOTES.md` evidence
- Phase 6: LanguageServices policy engine (timeout, cancel, stale-revision, failure isolation, limits, health)
- Phase 6: provider categories for highlights, type/call hierarchy, execute command, pull diagnostics
- Phase 6: full bidirectional LSP JSON-RPC (cancel, server requests, progress), framing caps, position map cache
- Phase 6: capability-gated adapters for all LanguageServices categories; process-group kill; restart backoff
- Phase 6: CI `lsp-matrix` job; `PHASE6-NOTES.md` evidence matrix
- Phase 5: View public API allowlist, package-scoped renderers, EditorAccessibility helpers
- Phase 5: UIKit marked-text composition, theme token overrides (`resolve` / `applyTokenMap`), highlight cancel on disappear
- Phase 5: reference workflow and IME composition model tests
- Phase 4: expanded LanguageDefinition, QueryKind, LanguageDetector, registry snapshots/diagnostics
- Phase 4: QuerySetLoader/GrammarIdentity, grammar-inventory.json, verify-grammars hermetic checks
- Phase 4: Swift/JSON grammar provenance constants and pack smoke/corpus tests
- Phase 3: transactional WorkspaceEdit with rollback, path security, FS directory watchers, workspace snapshots/trust
- Phase 3: SearchBackend, gitignore-aware native search, SearchReplaceService via WorkspaceEdit
- Phase 3: async commands, WhenClauseParser, keybinding conflict API, ranked command palette
- Phase 2 Core/Documents safety: `TextOffsetSemantics`, `DocumentStoreError`, stale-version apply, property/Unicode edit tests
- Atomic durable file IO (`DocumentIO`, temp + fsync + replace), coordinated IO, recovery journal, file identity / external-change detection, lifecycle policies, security-scoped bookmark helpers
- Fault-injection DocumentIO for data-loss prevention tests
- Stabilization program Phase 0: ADR-013 (Stable gate), ADR-014 (Swift-first extensions), ADR-015 (threat model), ADR-016 (platform profiles)
- `Docs/Architecture/CompatibilityProfile.toml`, `PRODUCT-OWNERS.md`, `EXTENSION-API-INVENTORY.md`, `PHASE0-NOTES.md`
- `scripts/dump-symbol-graphs.sh` for local per-product symbol-graph dumps
- Phase 1: `PlatformCapabilityProfile` / `CodeEditorPlatformError` and platform service protocols in `CodeEditorCore`
- Process fail-closed guards on LSP, Tasks, Terminal, SourceControl, and ExtensionHost
- Immutable grammar pins (`scripts/grammars.tsv` commit SHAs + checksums); pin check/record scripts
- CI workflow (`.github/workflows/ci.yml`): macOS debug/release, iOS Simulator build, empty-cache resolve, product smoke, coverage, API baselines, WASI pin, isolation/docs/format/license
- `Docs/Architecture/TOOLCHAIN.md`, `WASI-SDK.pin`, `PHASE1-NOTES.md`
- Local scripts: `verify-local.sh`, `smoke-products.sh`, `check-licenses.sh`, `check-format.sh`, `check-api-baseline.sh`, `check-wasi-sdk.sh`, `ci-bootstrap-grammars.sh`

### Fixed

- `scripts/update-grammars.sh` copies sibling headers (e.g. Haskell `unicode.h`) and rewrites flattened `common/` includes for TypeScript/TSX/PHP/OCaml so a clean clone can build after grammar generation
- Grammar updater checks out by immutable commit SHA when pinned

## [1.0.0] — Ready

First modular 1.0-ready release of the CodeEditorView package.

### Added

- Modular SwiftPM products for core, documents, commands, workspace, workbench, language services, extensions, extension host, LSP, search, tasks, terminal, and source control
- Product isolation script (`scripts/check-product-isolation.sh`)
- Architecture ADRs 001–012 and phase notes
- Guides: product selection, migration, extension authoring, API audit, API stability
- DocC landing pages for library products
- Examples: SmallEditor, FullWorkbench (plus existing CodeEditorViewDemo)

### Stability

- **Stable:** Core, Documents, LanguageSupport, View, TreeSitter, language pack registration
- **Evolving:** Commands, Workspace, Workbench, LanguageServices, Search, Tasks
- **Experimental:** Extensions, ExtensionHost, LSP, Terminal, SourceControl

### Notes

- Tagging `1.0.0` on the remote remains a maintainer action; this entry documents readiness.
- Experimental products may change in minor releases of 1.x.

## [0.x] — Pre-1.0 modularization

Incremental phases 1–12 delivered the product split prior to the stability policy in ADR-012.
