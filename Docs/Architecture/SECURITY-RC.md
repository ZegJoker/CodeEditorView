# Security RC pack (Phase 16)

## Threat model

- [ADR-015](ADR-015-extension-threat-model.md) — grants, native reliability boundary, Wasm sandbox preference

## App Review / distribution

- [APP-REVIEW.md](../Guides/APP-REVIEW.md) — shipping profile claims A–E
- [ADR-016](ADR-016-platform-profiles.md) — platform profiles
- Phase 15 install/runtime gates

## Supply chain

- Package signing / fail-closed keyring (Phase 14)
- SBOM + license policy
- Revocation + quarantine
- Scripts: `check-licenses.sh`, store revoke-check CLI

## Automated tests

```bash
swift test --filter Phase16Security
swift test --filter Phase14
swift test --filter Phase15
./scripts/check-security-rc.sh   # docs + Phase16Security (+ optional Phase14 signing)
```

## Secrets

Host-managed; extensions do not receive ambient credentials. Broker allowlists for process/download/npm.
