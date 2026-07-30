# Phase 13 notes — 1.0 readiness

## Guides

| Guide | Path |
|---|---|
| API stability / semver | `Docs/Guides/API-STABILITY.md` |
| API audit | `Docs/Guides/API-AUDIT.md` |
| Product selection | `Docs/Guides/PRODUCT-SELECTION.md` |
| Migration | `Docs/Guides/MIGRATION-1.0.md` |
| Extension authoring | `Docs/Guides/EXTENSION-AUTHORING.md` |

## Samples

| Sample | Profile |
|---|---|
| `Examples/SmallEditor` | View + LanguageSwift |
| `Examples/CodeEditorViewDemo` | Existing interactive demo |
| `Examples/FullWorkbench` | Workspace + Workbench + tooling sketch |

```bash
cd Examples/SmallEditor && swift build
cd Examples/FullWorkbench && swift build
```

## Release checklist

- [x] `swift test` (344 tests / 99 suites)
- [x] `scripts/check-product-isolation.sh`
- [x] `scripts/check-docs.sh`
- [x] README product table current
- [x] CHANGELOG `1.0.0` section complete
- [ ] Tag `1.0.0` (optional, human step)
- [ ] SPI / DocC host (optional)

## Related

- ADR-012
