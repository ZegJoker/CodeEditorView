# Phase 6 notes — Language runtime & LSP correctness

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md` §11.8–12, §13, Phase 6 gate  
**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD residual completion; no soft-stubs.

## Goal

Deterministic Tree-sitter off the main actor; race-free ordered LSP; full-text-correct sync under rapid edits; cross-file positions via snapshots; versioned diagnostics; honest real-server gate.

## Deliverables (residual pass)

| Item | Status |
|---|---|
| `LanguageDocumentActor` off-main parse/query + generation | Done |
| `TreeSitterHighlightProvider` delegates highlights to engine; stale gen discard | Done |
| `requestRaw` register-before-send; bounded earlyResponses | Done |
| Ordered inbound notification/request chain | Done |
| Full-text debounce + rapid-edit matrix vs mock server | Done |
| `negotiatedPositionEncoding` on session | Done |
| Dynamic registration tracks methods | Done |
| `LSPDiagnosticStore` version-aware clear | Done |
| `scripts/check-real-lsp.sh` (REQUIRE_REAL_LSP=1 hard) | Done |

## Gate evidence

```text
swift test --filter 'Phase6'
# 21 tests / 7 suites — all passed

./scripts/check-real-lsp.sh
# reports sourcekit-lsp / clangd when present
```

### Key tests

| Exit | Test |
|---|---|
| E1/E2 TS actor | `generationAdvancesAndStaleRejected`, `actorIsNotMainActorIsolated` |
| E6 register-before-send | `registerBeforeSendHandlesInstantReply` |
| E7 ordered inbound | `inboundNotificationsPreserveOrder` |
| E4 rapid edit | `rapidEditsFullTextMatchesServer` |
| E5/E8 encoding | `positionEncodingRecorded`, `nonASCIIPositionsRoundTripUTF16` |
| E12 diagnostics | `diagnosticStoreClearsOnEmptyPublishAndShutdown` |

## Residual vs full §13.12 Stable

Mock matrix covers protocol correctness. Full Stable still wants end-to-end scenarios against live sourcekit-lsp/clangd with `REQUIRE_REAL_LSP=1` in CI (script ready; not soft-skipped when required).

## Defects

LSP-001…LSP-009, TS-001…TS-002 closed with evidence above.

## Related

- Phase 4 `WorkspaceEditService` for applyEdit host wiring  
- Phase 1 grammar pins / verify-grammars  
