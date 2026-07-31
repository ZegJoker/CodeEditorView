# Phase 2 notes — Core and Document safety

## Goal

Fault injection cannot produce partial user content. Core edit invariants are property-tested; document I/O is atomic, fsynced, and identity-aware.

## Deliverables

### CodeEditorCore

| Item | Status |
|---|---|
| `DocumentStoreError` typed mutation/offset errors | Done |
| `TextOffsetSemantics` (UTF-16 primary, UTF-8, grapheme bounds, line-ending normalize) | Done |
| `apply(…, expectedVersion:)` stale-version check | Done |
| Range validation on apply | Done |
| `DocumentStore.storage` demoted to `package` | Done (View tests still access via package) |
| Sendable posture documented on `DocumentStore` / `ColumnSelectionFragment` | Done |
| Property tests: inverse edit sequences, multi-range inverse, stale version | Done |
| Unicode corpus edit survival | Done |
| `LineEnding: Codable` | Done |

### CodeEditorDocuments

| Item | Status |
|---|---|
| `DocumentIO` protocol + `LocalDocumentIO` (temp + fsync + replace) | Done |
| `FaultInjectingDocumentIO` for gate evidence | Done |
| `CoordinatedDocumentIO` (`NSFileCoordinator`) | Done |
| `DocumentCodec` encoding / BOM / line-ending policies | Done |
| `DocumentFileIdentity` + external change detection | Done |
| `RecoveryJournal` sidecar | Done |
| `SecurityScopedBookmark` helpers | Done |
| `DocumentLifecyclePolicy` (read-only, max load, journal, BOM, newlines) | Done |
| `LocalFileDocumentProvider` rebuilt on DocumentIO | Done |
| `TextDocument` fileIdentity / recovery / read-only apply | Done |
| URI canonicalization + registry lookup | Done |

### Fault-injection evidence

| Scenario | Result |
|---|---|
| Fault before replace | Original file bytes unchanged |
| Fault after temp write | Original file bytes unchanged |
| Read-only save | File unchanged, typed error |
| CRLF convert round-trip | File bytes are CRLF |
| UTF-8 BOM policy | BOM written and detected |
| Recovery journal | Restores dirty text; clear after success path |
| External modify | Hash change → `.externalModified`; delete → `.deleted` |

## Gate criteria

- [x] Atomic save path uses temp + fsync + replace; fault tests prove no partial user content  
- [x] Encoding/line-ending/BOM round-trip matrix green  
- [x] External change detection (unchanged / modified / deleted)  
- [x] Recovery journal restores dirty content  
- [x] Core edit property tests + Unicode corpus green  
- [x] Documented Sendable posture for DocumentStore  
- [x] PHASE2-NOTES + CHANGELOG; `swift test` and isolation  

**Local verification (2026-07-31):** `swift test` → **393 tests / 109 suites — all passed**.

## Residual / follow-ups

- Full public Core declaration inventory freeze (symbol-graph digester) remains Phase 1 tooling + ongoing  
- Large-file streaming load (beyond max-bytes reject)  
- Autosave timer / dirty-close UX (policy types exist; host wires timers)  
- True rename detection across paths (identity-only “moved” left for Workspace phase)  
- Benchmark numbers for 1MB/10MB docs (manual; not CI)

## Related

- ADR-013 Stable gate  
- Phase 3: Commands / Workspace / Search transactions  
