# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with stability tiers described in `Docs/Guides/API-STABILITY.md`.

## Unreleased

### Changed — Audit remediation 2026-08 (pre-alpha reset)

- **Phase 5 complete (TER-001…TER-008 / §20–21 Ghostty terminal):**
  - `CGhosttyShim` + `ce_pty_spawn` (no Swift in child); `LocalPTYTransport` non-lossy
  - `TerminalService` + `GhosttySessionController` + AppKit/SwiftUI surface
  - Workbench terminal panel Ghostty-backed (not custom `TerminalScreen` dump)
  - DAP `GhosttyRunInTerminalHandler`; security policy; a11y adapter
  - Pin check script; fail-closed when `requireLinked` and Ghostty unlinked
- **Phase 4 complete (WSP-001…WSP-007 / CMD-001…CMD-004 / §8–9) + TDD residual pass:**
  - Dirty-close coordinator on all tab/pane/window paths; UI Close Pane → `requestClosePane`
  - Workspace edit journal + fault matrix including `duringRollback` typed catastrophic
  - `RelativeWorkspacePath` path security corpus; FS actor stress/cancel tests; FSEvents overflow
  - Trust default restricted with capability gates; on-disk golden restoration fixtures
  - `RegistrationBag` host lifetime; chord SM (prefix wait / timeout / Escape)
  - `CommandContextSnapshot` from real focus/trust; typed notFound/disabled/unsupported
- **Phase 3 complete (UI-001…UI-009 / TS-001 / §11):**
  - MarkedTextSession provisional IME (no per-keystroke undo)
  - AppKit replacementRange; grapheme delete; code subword navigation
  - Drag move transaction; EditorTextServicesPolicy
  - Tree-sitter runtime without nonisolated(unsafe) globals
  - Layout max-width cache; virtualized a11y; signposts/harness
- **Phase 2 complete (DOC-001…DOC-010 / §7.1–7.12):**
  - Atomic multi-edit staging + overlap reject + property/fault tests
  - Exact offset conversion (no EOF fallback); boundary policies
  - Throwing undo/redo; dirty from `savedVersion`
  - Conflict-safe save; streaming `readContentAndIdentity` (no full-file identity re-read)
  - Encoding fidelity (reject `.other`); versioned recovery journal; bounded streams
  - `DocumentStore` no longer `@unchecked Sendable`
- **Withdrawn** Stable/1.0-Ready claims pending open P0/P1 closure (`Docs/Architecture/DEFECTS.md`)
- DOC-001: atomic multi-edit with full prevalidation and staging buffer
- DOC-002: throwing undo/redo; stack ownership only after successful apply; savedVersion tracking
- DOC-003: exact UTF offset conversion; never map invalid interior offsets to EOF
- EXT-001: validated `ExtensionID` grammar; filesystem uses `directoryKey` hash
- EXT-002/003/004: package file-set equality, publisher binding, fail-closed install policy
- WASM-001: WasmKit product documented as **simulation engine** (no bytecode execution)
- IOS-001: removed duplicate UIKit accessibility overrides
- LSP-001: debounced document sync uses full-text resync
- CMD-001/002: retain contribution tokens; chord prefix ambiguity state machine
- TASK-001: problem matchers keep line/column (no `line*200+col` fabrication)
- SCM-001: Git rename porcelain dest/src; component-aware path containment
- DAP-001: register DAP pending continuation before transport write
- WSP-001: `requestCloseTab` + `WorkspaceCloseDelegate`; fail-closed without host decision
- WSP-002: durable workspace-edit journal, byte-exact FS capture, rollback errors never swallowed
- DOC-004: conflict-safe save (`expectedIdentity`, `SaveResult`); metadata-first bounded reads
- PATH/TRUST/RESTORE: typed path security, trust defaults restricted, unknown schemas rejected
- WB-001: real Output / Problems / Terminal utility panels (PTY-backed terminal UI)
- TER-001 partial: non-lossy terminal stream; VT UTF-8 double-append fixed; OSC ST handling
- CommandID validation + typed notFound/disabled results; chord ambiguity state machine
- **Phase 1 complete (PKG-001 / CI-004 / CI-008 / CI-009 / CI-010 / CI-011):**
  - Grammars committed in `Packages/CodeEditorGrammars` (deterministic path package); root has zero `Grammars/` targets
  - Retired `filter-package-grammars.py` (fails if invoked)
  - Hard `swift-format` + WASI SDK gates; `XCODE.pin` (26.4)
  - Source-archive rehearsal script + CI job
  - Real macOS/iOS example hosts with `xcodebuild test`
  - Typed `LanguagePackError` for missing query resources
- WASM-002: real WasmKit `parseWasm` / instantiate / export call path + RealWasmExecutionTests
- TER-001: `CGhosttyShim` C ABI, `CodeEditorTerminalGhostty`, GHOSTTY.pin, workbench PTY terminal
- LSP-003: `WorkspaceSnapshotResolver` for cross-file location text
- TASK-002: rolling readiness window; background deps require `.ready`
- TS-001: `TreeSitterLanguageRuntime` actor; off-main configuration load
- UI-001: grapheme-aware UITextInput movement, selection rects, BiDi, marked subrange
- CI-001: `scripts/generate-release-evidence.sh` emits commit/toolchain/test/defect evidence
- Structured defect register: `Docs/Architecture/defects.json`

### Added

- Phase 16: RC gates — API freeze baselines, product scorecards, DEFECTS register, S0–S4 conformance report
- Phase 16: migration/rollback rehearsals, soak/performance/security tests, `verify-rc.sh`, RC checklist
- Phase 15: shipping profiles A–E (`ShippingProfileID`), expanded capability matrix (Wasm/install/registry/remote)
- Phase 15: `ExtensionHostProfile`, install policy gates, RuntimeSelector profile gates, native helper policy
- Phase 15: remote tooling coordinator (LS fallback), runnability descriptors, App Review guide
- Phase 14: versioned extension store (immutable versions, atomic current/previous, recover, user-data preserve)
- Phase 14: fail-closed publisher keyring policy, SBOM/license enforcement, revocation list, registry client
- Phase 14: store telemetry NDJSON, trust UI descriptors, CLI sign/verify/sbom/install/update/rollback/recover
- Phase 13: `CodeEditorDAP` client (framing, session/pool, mock adapter matrix, reverse `runInTerminal`)
- Phase 13: debug adapter + MCP server launch plans/providers, TOML tables, host executors
- Phase 13: slash commands (compatibility) with stream/cancel/sanitize; documentation index service with quotas
- Phase 13: `CompatibilityProfile` loader + feature labels; fixtures `dap-procedural` / `mcp-procedural`
- Phase 12: language-server launch plans, `LanguageServerProvider`, TOML `[language_servers.*]`, `LanguageServerLanguageMap`
- Phase 12: host executor + coordinator (broker materialize, pool, settings invalidation, process allowlist)
- Phase 12: worktree `which` / filtered environment, resolve context builder, wire codec for `ls.*`
- Phase 12: completion **and** symbol label hooks on LSP adapters; status/diagnostics store
- Phase 12: built-in / native guest / Wasm `ls.*` dispatch; download digest enforcement; `PHASE12-NOTES.md` S2 matrix
- Phase 11: `CodeEditorWasmEngine` + `CodeEditorWasmEngineWasmKit` (WasmKit) + `CodeEditorExtensionWasmGuest`
- Phase 11: core-Wasm ABI session, SwiftWasm runtime driver, resource limits, malicious fixtures
- Phase 11: `scripts/build-wasm-extension.sh` / `check-wasm-fixture.sh`; ADR-017 ABI go/no-go (experimental)
- Phase 10: `CodeEditorExtensionProtocol` CBOR wire + framing + method catalog/schema hash
- Phase 10: `CodeEditorExtensionGuest` + `ConformanceExtensionGuest` native helper runtime
- Phase 10: runtime drivers/orchestrator, process-group transport, restart/quarantine
- Phase 10: capability broker (worktree/project/settings/storage/process/download/npm)
- Phase 10: Ed25519 package signing/verify + trust classes for native launch
- Phase 9: `CodeEditorExtensionAPI` author product (identity, manifest, author protocol, contribution DTOs)
- Phase 9: `extension.toml` v1 parser/validator, `ValidatedContributionPlan`, SHA-256 package digests
- Phase 9: declarative loaders for themes, icon themes, snippets, languages, grammars, queries
- Phase 9: immutable contribution snapshots + collision diagnostics; `ExtensionPackageManager` lifecycle (install/enable/disable/update/rollback/uninstall/dev-reload)
- Phase 9: `codeeditor-extension` CLI (`validate`, `digest`, `migrate` JSON→TOML + optional Swift template)
- Phase 9: S0/S1 fixtures, TOML corpus, migration goldens; `PHASE9-NOTES.md`
- Phase 8: Workbench lifecycle, multi-window registry, restoration encode/decode
- Phase 8: contribution descriptors, fault isolation, focus routing, command validation
- Phase 8: cancellable workspace index for Open Quickly; tooling failure surfaces; host builder
- Phase 8: accessibility identifiers, L10n keys, reduced-motion chrome; `PHASE8-NOTES.md`
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

## [1.0.0] — SUPERSEDED / NOT QUALIFIED

> **Do not treat this entry as release readiness.** The 2026-08 deep audit found open P0/P1
> defects (data integrity, security, fake Wasm path, terminal, CI honesty). The package remains
> **pre-alpha** until `Docs/Architecture/DEFECTS.md` has no open P0/P1 and §26 gates pass.

Historical note: modular product split and ADRs 001–012 were landed under this label incorrectly.

### Historical content (not a qualification claim)

- Modular SwiftPM products for core, documents, commands, workspace, workbench, language services, extensions, extension host, LSP, search, tasks, terminal, and source control
- Product isolation script (`scripts/check-product-isolation.sh`)
- Architecture ADRs 001–012 and phase notes
- Guides: product selection, migration, extension authoring, API audit, API stability
- DocC landing pages for library products
- Examples: SmallEditor, FullWorkbench (plus existing CodeEditorViewDemo)

## [0.x] — Pre-1.0 modularization

Incremental phases 1–12 delivered the product split prior to the stability policy in ADR-012.
