# Phase 2 notes — Document substrate (complete)

## Goal

Trustworthy text storage, positions, undo, and document IO before tooling work.

## Exit criteria (all met)

| Criterion | Evidence |
|---|---|
| Atomic multi-edit | `DocumentStore.apply` validates all ranges, rejects overlap, stages mutations, single commit; `DocumentStoreAtomicityTests` |
| Exact offsets (no EOF redirect) | `TextOffsetSemantics.scalarIndex` throws under `.exact`; `Phase2CoreResidualTests.scalarIndexExactNeverFallsBackToEOF` |
| Boundary policies | `.exact`, `.roundDownToScalar`, `.roundUpToScalar`, `.roundToGrapheme` on convert APIs |
| Throwing undo/redo | `UndoCoordinator.undoGroup` / `redoGroup` + `defer`; `failedApplyLeavesStackUnchanged` |
| Dirty from savedVersion | `TextDocument.recomputeDirtyFromSavedVersion` |
| Conflict-safe save | `LocalFileDocumentProvider.save(..., expectedIdentity:, policy:)`; `conflictSaveDetectsExternalModify` |
| Streaming size gate + identity | `LocalDocumentIO.readContentAndIdentity`; `singlePassIdentityMatchesHash`, `maxLoadBytesRejectsOversized` |
| Encoding fidelity | `DocumentCodec` rejects `.other`; no silent UTF-8 remap |
| Recovery journal | Versioned JSON envelope + checksum + quota + quarantine; `recoveryJournalChecksumRejectsTamper` |
| Bounded streams | `EditorEventStream` / `TextDocument.makeEventStream` use `bufferingNewest` |
| Concurrency | `DocumentStore` is **not** `@unchecked Sendable`; documented main-actor-affine ownership |

## Defects closed

DOC-001…DOC-010 (audit §7.1–7.12).

## Local verification

```bash
swift test --filter 'CodeEditorCoreTests|CodeEditorDocumentsTests'
rg 'Data\(contentsOf' Sources/CodeEditorDocuments  # should be empty for production IO
rg 'endIndex' Sources/CodeEditorCore/Document/TextOffsetSemantics.swift  # only legitimate end positions
```
