# Phase 14 notes — Store, signing, update, rollback, and migration

## Goal

Operational store parity: versioned installs, fail-closed trust, SBOM/licenses, revocation, recovery, telemetry, activation gate, and a full CLI — **no soft-stubs**.

## Layout

```
{installRoot}/
  packages/{id}/{semver}/   # immutable verified tree
  packages/{id}/current     # pointer file
  packages/{id}/previous
  state/packages.json
  data/{id}/                # survives update/uninstall
  cache/downloads/
  revocation/list.json
  telemetry/migration-events.ndjson
```

## Components

| Piece | Module |
|---|---|
| `ExtensionPackageManager` (versioned + recover) | Extensions |
| `ExtensionRegistryClient` (+ materialize) | Extensions |
| `PackageSBOM` / `LicensePolicy` | Extensions |
| `StoreTelemetrySink` | Extensions |
| `ExtensionPackageSigner` / `Verifier` / keyring | Host |
| `HostPackageVerifier` | Host → manager injection |
| `ExtensionHostOrchestrator.attachPackageManager` | Host activation gate |
| Trust UI descriptors + `ExtensionManagerModel` | API + Host |
| CLI `codeeditor-extension` | CLI |

## Trust policy (fail-closed)

- Empty keyring **rejects** signed packages unless `allowUnknownSelfSigned` (tests/CLI authoring).
- Revoked key IDs fail verify.
- Dev unsigned packages only when `allowWorkspaceDevNative`.
- License/SBOM optional or required via `LicensePolicy`.
- Orchestrator re-verifies `packageRoot` under `policy.trust` before starting a driver (skips pure built-in with no root).
- Attached store: `assertCanActivate` denies revoked / quarantined / disabled packages and emits `activation.denied`.

## CLI surface

```
validate | digest | migrate | gen-key | sign | verify | sbom | package
install | update | rollback | list | recover | revoke-check
```

## Fixtures

`Tests/Fixtures/Store/`:

- `index.json` — local registry index
- `packages/com.example.signed/1.0.0/`
- `packages/com.example.revoked/1.0.0/`
- `keyring.json`, `revocation.json`

## Gate evidence

```bash
swift test --filter Phase14
swift test --filter ExtensionPackageManager
swift run codeeditor-extension verify --dir <signed-pkg> --keyring <keyring>
./scripts/check-product-isolation.sh
./scripts/check-docs.sh
```

## Soft-stub ban (implemented)

| Forbidden | Actual |
|---|---|
| In-memory-only rollback | File version pointer flip |
| Wipe previous on update | Immutable version dirs |
| Empty keyring accept-any | Fail closed |
| Revocation log-only | Install/activate deny + quarantine |
| Empty SBOM marked valid | Real file inventory + hashes |
| CLI fake ok | Manager/verify calls |
| Activation skips verify | Orchestrator gate |
| Recover only in-memory | Staging purge + FS pointer reconcile |
