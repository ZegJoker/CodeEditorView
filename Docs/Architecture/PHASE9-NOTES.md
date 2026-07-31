# Phase 9 notes — Author API + TOML data extensions

## Goal

Extract a transport-neutral **CodeEditorExtensionAPI** product, make **`extension.toml`** the canonical package format, load declarative data contributions into immutable plans/registries, and ship migration tooling. Data-only packages work without executable activation on iOS/macOS.

## Products

| Product | Role |
|---|---|
| `CodeEditorExtensionAPI` | Author SDK: identity, manifest, author protocol, contribution DTOs, TOML loader, digests, migration |
| `CodeEditorExtensions` | Host façade: runtime, registrars, stores, package manager, re-exports API |
| `codeeditor-extension` | CLI: `validate`, `digest`, `migrate` |

## Isolation

`CodeEditorExtensionAPI` depends only on Core, Documents, Commands, LanguageSupport.

It must **not** import View, Workbench, ExtensionHost, LSP, tooling products, UI frameworks, Wasm engines, or process hosts (enforced by `scripts/check-product-isolation.sh`).

Authors depend on:

```text
CodeEditorExtensionAPI
  └── Core / Documents / Commands / LanguageSupport
```

Host apps still use `CodeEditorExtensions` for runtime activation.

## Package layout

```text
my-extension/
├── extension.toml          # canonical
├── themes/
├── icon_themes/
├── snippets/
├── languages/<id>/
│   ├── config.toml
│   └── *.scm
├── grammars/<id>/
│   └── grammar.toml
├── assets/
└── extension.json          # legacy only; TOML wins if both present
```

## Manifest (`extension.toml` v1)

```toml
id = "com.example.theme"
name = "Example Theme"
version = "1.0.0"
schema_version = 1
api_version = "1.0"

[activation]
events = ["startup"]

[runtime]
kind = "data-only"

capabilities = ["themes", "snippets"]
```

Unsupported / unmapped fields produce diagnostics (notes/warnings), not silent success.

## Author API

```swift
import CodeEditorExtensionAPI

struct Hello: EditorExtension {
    let manifest = ExtensionManifest(
        id: "com.example.hello",
        displayName: "Hello",
        activationEvents: [.startup]
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        context.info("activated")
    }
}
```

Host runtime still provides concrete `ExtensionContext` with registrars:

```swift
import CodeEditorExtensions

func activate(in context: any ExtensionAuthorContext) async throws {
    guard let ctx = context as? ExtensionContext else { return }
    if let commands = ctx.commands {
        context.track(await commands.registerAsync(...))
    }
}
```

## Data loading

```swift
let plan = try ExtensionPackageLoader.load(directory: packageURL)
// ValidatedContributionPlan + digest + diagnostics + parity profile

let bundle = try DataExtensionLoader.load(from: packageURL)
await runtime.register(DataExtensionLoader.makeExtension(from: bundle))
try await runtime.activate(id: plan.packageID)
```

Parity profiles:

| Profile | Meaning |
|---|---|
| `codeeditor-data-s0` | Manifest validates; no data contributions |
| `codeeditor-data-s1` | Themes / icons / snippets / languages / grammars / queries loaded |
| `codeeditor-data-s1-legacy-json` | Loaded via legacy `extension.json` |

## Package manager

`ExtensionPackageManager` (actor):

- install / enable / disable / update / rollback / uninstall
- dev reload (`reloadDev`) shadows installed same id
- corrupted-state recovery
- immutable `ExtensionContributionSnapshot` + bounded `AsyncStream`
- collision diagnostics via `ImmutableContributionRegistry`

## CLI

```bash
swift run codeeditor-extension validate path/to/package
swift run codeeditor-extension digest path/to/package
swift run codeeditor-extension migrate \
  --from extension.json \
  --to extension.toml \
  --dir path/to/package \
  --report MIGRATION-REPORT.md \
  --swift-template
```

## Migration rules

- JSON → TOML mapping for id/name/version/activation/capabilities/permissions
- Themes, snippets, languages, icon themes exported to conventional folders
- Dual manifest: **TOML wins**, warning `package.dual_manifest`
- Legacy JSON only when `allowLegacyJSON` is true
- Keybindings noted in migration TODOs

## Fixtures (S0/S1)

| Path | Level |
|---|---|
| `Tests/Fixtures/Extensions/s0-basic` | S0 |
| `Tests/Fixtures/Extensions/s1-data` | S1 |
| `Tests/Fixtures/Extensions/legacy-json` | migration |
| `Tests/Fixtures/Extensions/corpus/*` | TOML corpus |

## Deliverables checklist

| Item | Status |
|---|---|
| `CodeEditorExtensionAPI` product | Done |
| `@_exported` re-exports from Extensions | Done |
| `extension.toml` v1 parser/validator | Done |
| `ValidatedContributionPlan` | Done |
| Canonical package digests (SHA-256) | Done |
| Immutable contribution snapshots / collisions | Done |
| Themes / icons / snippets / languages / grammars / queries | Done |
| `ExtensionPackageManager` lifecycle + dev reload | Done |
| JSON migration (`ExtensionMigration` + CLI) | Done |
| S0/S1 fixtures + tests | Done |
| Isolation script + authoring docs | Done |

## Explicitly not Phase 9

- Native process / Wasm drivers (Phases 10–11)
- Language-server procedural parity (Phase 12)
- Full store signatures / revocation marketplace (later)
- `CodeEditorExtensionTesting` product (later phase)

## Gate evidence

- `swift test --filter CodeEditorExtensionAPITests`
- `swift test --filter CodeEditorExtensionsTests`
- `scripts/check-product-isolation.sh`
- CLI validate against `Tests/Fixtures/Extensions/s0-basic` and `s1-data`
