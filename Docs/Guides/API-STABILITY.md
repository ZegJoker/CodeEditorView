# API stability and semantic versioning

This package targets **Swift Package Manager 1.0 readiness** with explicit stability tiers. Tagging `1.0.0` is a release decision; this document defines the contract once that tag is cut.

## Platforms and language

| Requirement | Value |
|---|---|
| Swift | 6 (package `swiftLanguageModes: [.v6]`) |
| macOS | 15+ |
| iOS | 18+ |

## What counts as public API

- `public` types, methods, properties, and free functions in library product modules
- Documented product dependency graphs (isolation allowlists)

**Not** public API:

- `internal` / `private` / underscored names
- `Tests/` and `Examples/`
- Grammar C sources and query resources (format may evolve; pack registration API is public)
- Wire formats internal to LSP / ExtensionHost (unless documented as RPC schema versions)

## Stability tiers

| Tier | Semver commitment | Products |
|---|---|---|
| **Stable** | Breaking changes require a **major** version | `CodeEditorCore`, `CodeEditorDocuments`, `CodeEditorLanguageSupport`, `CodeEditorView`, `CodeEditorTreeSitter`, language pack **registration** surface (`CodeEditorLanguageSwift` / `JSON` / `Languages` bootstrap) |
| **Evolving** | Prefer additive **minor** changes; rare breaks allowed with migration notes in the same major | `CodeEditorCommands`, `CodeEditorWorkspace`, `CodeEditorWorkbench`, `CodeEditorLanguageServices`, `CodeEditorSearch`, `CodeEditorTasks` |
| **Experimental** | May break in **minor** releases; pin carefully | `CodeEditorExtensions`, `CodeEditorExtensionHost`, `CodeEditorLSP`, `CodeEditorTerminal`, `CodeEditorSourceControl` |

Experimental products still ship isolation tests and PHASE notes; they are usable in production hosts that accept churn.

## Versioning policy

1. **MAJOR** — remove/rename Stable public API, raise platform floors, or change Swift language mode requirements.
2. **MINOR** — additive public API; Evolving may adjust shapes with `CHANGELOG` + guide notes; Experimental may break.
3. **PATCH** — bug fixes, docs, tests, isolation; no intentional public API change.

## Deprecation

- Prefer `@available(*, deprecated, message:)` for at least one minor before removal of Stable/Evolving API.
- Experimental API may be removed without deprecation if called out in `CHANGELOG`.

## Related

- [API audit](API-AUDIT.md)
- [ADR-012](../Architecture/ADR-012-1.0-stability.md)
- [Product selection](PRODUCT-SELECTION.md)
