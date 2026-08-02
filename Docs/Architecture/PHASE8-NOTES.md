# Phase 8 notes — Secure extension package / store / broker

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md`  
- Phase gate: **§ Phase 8**  
- Findings: **§15.1–15.23**

**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD residual completion; no soft-stubs.

> Workbench lifecycle notes previously lived under this filename (pre-audit numbering). Workbench tooling models closed under **Phase 7 (WB-007)**. This document is the audit Phase 8 security gate.

## Goal

Make bundled and downloadable extension data safe before executing third-party code: validated IDs, sealed package membership, fail-closed trust/store, durable install recovery, and a real broker for storage/download/npm/process/worktree.

## Deliverables

| Item | Status |
|---|---|
| ExtensionID corpus + `directoryKey` FS roots (broker storage/download/npm) | Done |
| File-set equality; reject symlink/special/key material | Done |
| Publisher subject binding; subject-swap deny | Done |
| Production fail-closed manager; corrupt state store quarantine | Done |
| SBOM/broker digests fail closed (never length) | Done |
| TOML fail-closed api_version + unknown activation/capability/permission | Done |
| Recover re-verifies packages before trust | Done |
| Storage overwrite-correct quota + SHA-256 key encoding | Done |
| Durable settings under storage root | Done |
| Streaming download + mid-stream cap + redirect guard | Done |
| Host-owned npm materializer from local registry (no stub-only package.json) | Done |
| Process allowlist: canonical/trusted-dir paths only | Done |
| Multi-root worktree handles + read size limit + revoke | Done |
| `ExtensionSDKConformance` kit for data-only packages | Done |
| `PHASE8-NOTES` rewritten to extension security | Done |

## Gate evidence

```text
swift test --filter 'Phase8|Phase10Host|Phase14Signing|Phase14Store'
# Phase8 suites green; Phase10 broker/signing; Phase14 signing/store

./scripts/check-defects.sh
```

### Exit criteria map

| # | Proof |
|---|---|
| E1 | `extensionIDCorpusRejectsTraversal`, `packageManagerUsesDirectoryKey` |
| E2 | `rejectUnsignedExtraFile`, `rejectKeyMaterialInPackage` |
| E3 | `subjectSwapFailsWithTrustedKey` |
| E4–E5 | `corruptDurableStateQuarantinesStore` |
| E6 | `sbomDigestIsCryptographic` |
| E8–E9 | `unknownActivationEventFails`, `invalidAPIVersionFails` |
| E11 | `storageOverwriteDoesNotDoubleQuota` |
| E12 | `settingsPersistAcrossBrokerInstances` |
| E13–E14 | streaming download path + `npmMaterializesFromRegistryNotStub` / `npmInstallNoScripts` |
| E15 | `processBasenameOnlyAttackDenied` |
| E16–E17 | `multiRootWorktreeHandles`, `revokeExtensionInvalidatesHandles` |
| E18 | `sdkConformanceDataOnly` + this file |

## Defects closed

EXT-001…EXT-016 (including reopened residual proof for EXT-001…004).

## Related

- Phase 7 tasks/DAP/SCM  
- Phase 9 (audit) real Wasm execution  
- Phase 14 store layout (operational) + this phase security hardening  
