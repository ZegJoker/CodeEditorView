# Release candidate checklist

Operator checklist for cutting a release candidate from this repository. Library gates must pass before host apps ship.

## Automated (required)

```bash
./scripts/verify-rc.sh
```

Includes: isolation, docs, feature profiles, scorecards, defects (no open P0/P1), API freeze, accessibility, Phase16 tests, examples resolve.

Optional longer suites:

```bash
./scripts/generate-conformance-report.sh
./scripts/check-security-rc.sh
swift test
./scripts/smoke-products.sh
```

## Manual / host app

- [ ] Choose `ShippingProfileID` matching distribution (direct / MAS / iOS / enterprise)
- [ ] Wire `ExtensionExecutionPolicy.shipping` + install policy
- [ ] VoiceOver / keyboard pass on host UI binding Workbench accessibility IDs
- [ ] Notarization / sandbox entitlements (direct/MAS) as applicable
- [ ] Market only CodeEditor S0–S4 claims; do not imply third-party editor binary drop-in compatibility
- [ ] Review [DEFECTS.md](../Architecture/DEFECTS.md) (must have no open rows)

## Artifacts to attach to RC notes

- `Docs/Architecture/CONFORMANCE-REPORT.md`
- `Docs/Architecture/PRODUCT-SCORECARDS.md`
- `Docs/Architecture/API-FREEZE.md`
- `Baselines/api/PRODUCTS.txt`
- CI green URL / local `verify-rc` log
