# Phase 4 notes — Language metadata, Tree-sitter, reproducible packs

## Goal

Every grammar/query loads hermetically; mutable upstream refs are zero; language detection and query kinds are typed and tested.

## Deliverables

### LanguageSupport

| Item | Status |
|---|---|
| `QueryKind` enum | Done |
| Expanded `LanguageDefinition` (filenames, first-line, content patterns, priority, tab, brackets, queryKinds, tooling IDs, allowsComments) | Done |
| `LanguageDetector` | Done |
| Injectable `LanguageRegistry` + `snapshot()` + registration diagnostics | Done |
| Detection / snapshot / QueryKind tests | Done |

### TreeSitter

| Item | Status |
|---|---|
| `QuerySetLoader` + `TreeSitterQueryLimits` + `GrammarIdentity` | Done |
| Highlight config uses query set loader | Done |
| Cache stores grammar identity | Done |

### Packs & inventory

| Item | Status |
|---|---|
| Swift/JSON `grammarCommit` / URL / SHA256 constants | Done |
| Swift queryKinds + Package.swift filename | Done |
| JSON `allowsComments = false`, jsonc extension | Done |
| `scripts/generate-grammar-inventory.sh` → `grammar-inventory.json` (39) | Done |
| `scripts/verify-grammars.sh` pin + checksum hermetic check | Done |
| Wired into `verify-local.sh` | Done |
| Bootstrap smoke + corpus tests | Done |

## Gate evidence

| Check | Result |
|---|---|
| Mutable grammar refs | **0** (`check-grammar-pins`) |
| parser.c checksums vs tsv (when Grammars present) | Pass (`verify-grammars`) |
| Inventory unique names/symbols | Pass |
| Detection matrix | Pass |
| Swift/JSON configs load | Pass |
| `swift test` | **418 tests / 117 suites — all passed** |

## Residual

- Full query-kind goldens for every language (smoke only for suite-wide highlights presence)
- JSONC as separate language id (documented; extension maps to JSON grammar)
- Injection recursion enforcement beyond documented limit constant
- License field still best-effort MIT for most tree-sitter repos

## Related

- Phase 1 immutable pins  
- Phase 5 View façade  
- Phase 9 Zed language config.toml import  
