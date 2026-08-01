# API freeze (Phase 16)

## Policy

As of Phase 16 RC, **Stable-tier** library products have a frozen public surface inventory under `Baselines/api/*.public.txt` (source-extracted public types/funcs/vars).

| Tier | Freeze behavior |
|---|---|
| **Stable** | `./scripts/check-api-freeze.sh` fails on drift |
| **Evolving** | Inventory tracked; additive preferred (API-STABILITY.md) |
| **Experimental** | Inventory tracked; may change in minor releases |

Stable products under freeze:

- CodeEditorCore, CodeEditorDocuments, CodeEditorLanguageSupport
- CodeEditorView, CodeEditorTreeSitter
- CodeEditorLanguageSwift, CodeEditorLanguageJSON, CodeEditorLanguages

## Update procedure (intentional break/add)

```bash
# After intentional public API change on Stable products:
ALLOW_API_DIFF=1 ./scripts/check-api-freeze.sh
# Or regenerate inventories:
./scripts/extract-public-api.sh Baselines/api
git add Baselines/api
```

Document the change in `CHANGELOG.md` and, for removals, use deprecation first (API-STABILITY.md).

## Related

- `scripts/extract-public-api.sh`
- `scripts/check-api-freeze.sh`
- [API-STABILITY](../Guides/API-STABILITY.md)
- [PRODUCT-SCORECARDS](PRODUCT-SCORECARDS.md)
