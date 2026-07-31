# Extension authoring guide

Extensions contribute language features and data without forking the editor.

| Kind | Prefer |
|---|---|
| Data (themes, icons, snippets, language metadata) | `extension.toml` package — no code |
| Procedural Swift (commands, language services) | In-process types depending on **`CodeEditorExtensionAPI`** |
| Crash isolation | Out-of-process host (Phase 10+) |

## Author dependency rule

```text
Your extension package
  └── CodeEditorExtensionAPI
        └── Core / Documents / Commands / LanguageSupport
```

Do **not** import `CodeEditorView`, `CodeEditorWorkbench`, `CodeEditorExtensionHost`, UI frameworks, or process/Wasm engines from author code.

Host apps use `CodeEditorExtensions` for runtime activation and re-export the API (`@_exported`).

## Concepts

| Concept | Module |
|---|---|
| Identity, manifest, author protocol, contribution DTOs | `CodeEditorExtensionAPI` |
| TOML / JSON package loading, digests, migration | `CodeEditorExtensionAPI` |
| `ExtensionRuntime`, registrars, stores, package manager | `CodeEditorExtensions` |
| Remote host + RPC | `CodeEditorExtensionHost` |

## Package layout

```text
my-extension/
├── extension.toml
├── themes/
├── icon_themes/
├── snippets/
├── languages/<id>/config.toml
├── languages/<id>/*.scm
├── grammars/<id>/
└── assets/
```

### `extension.toml` (canonical)

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

Validate with:

```bash
swift run codeeditor-extension validate ./my-extension
swift run codeeditor-extension digest ./my-extension
```

## In-process Swift extension

```swift
import CodeEditorExtensionAPI
// Host may also import CodeEditorExtensions for ExtensionContext registrars
import CodeEditorExtensions
import CodeEditorCommands

struct HelloExtension: EditorExtension {
    let manifest = ExtensionManifest(
        id: "com.example.hello",
        displayName: "Hello",
        activationEvents: [.startup],
        requiredHostCapabilities: [.commands]
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let ctx = context as? ExtensionContext else {
            context.info("activated without host registrars")
            return
        }
        let command = await MainActor.run {
            EditorCommand(id: "com.example.hello.say", title: "Say Hello") { _ in }
        }
        if let commands = ctx.commands {
            context.track(await commands.registerAsync(command))
        }
    }
}

// Host:
await runtime.register(HelloExtension())
await runtime.fire(.startup)
```

## Data-only package

Load declarative contributions without writing Swift:

```swift
let plan = try ExtensionPackageLoader.load(directory: packageURL)
await runtime.register(DataExtensionLoader.makeExtension(from: plan))
try await runtime.activate(id: plan.packageID)
```

Themes live under `themes/*.json` (or `.toml`), snippets under `snippets/*.json`, languages under `languages/<id>/config.toml` plus optional Tree-sitter query files.

## Migrating from `extension.json`

```bash
swift run codeeditor-extension migrate \
  --from extension.json \
  --to extension.toml \
  --dir ./my-extension \
  --report ./MIGRATION-REPORT.md \
  --swift-template
```

Rules:

- `extension.toml` is canonical; if both files exist, **TOML wins** (warning).
- Legacy JSON remains readable under `allowLegacyJSON` for a documented window.
- Migration writes contribution folders and a TODO report for ambiguous fields.

## Permissions

Request only what you need. The host grants the intersection of requests and policy. Panel registration requires `presentUI`. Storage paths cannot escape the extension sandbox.

## Native-process helper (Phase 10)

Authors link `CodeEditorExtensionGuest` + `CodeEditorExtensionAPI` (+ protocol transitively):

```swift
import CodeEditorExtensionAPI
import CodeEditorExtensionGuest

@main
struct MyHelper {
    static func main() async {
        await ExtensionGuestMain.run(extension: MyExtension())
    }
}
```

Wire format is CBOR with a 4-byte length prefix (not JSON). Host policy selects built-in vs native-process based on artifacts and trust (`trustedSigned` / `workspaceDev`).

Native helpers are a **reliability** boundary—not a sandbox—unless an OS sandbox is applied.

## Out-of-process (legacy remote adapters)

```swift
let pair = MockRemoteExtensionTransport.makePair()
let server = RemoteExtensionServer(extension: myExt, transport: pair.remote)
await server.run()
```

Production apps supply process transports; **do not** call private LaunchServices APIs (ADR-011).

## Do not

- Import `CodeEditorView` / SwiftUI from extension library code intended for headless hosts
- Bypass `WorkspaceEdit` for multi-file edits
- Assume experimental ExtensionHost RPC is stable across minors without pinning
- Ship both independent JSON and TOML contribution sets (TOML is sole winner)

## Related

- [PHASE9-NOTES](../Architecture/PHASE9-NOTES.md)
- ADR-008, ADR-011, ADR-014
- [Product selection](PRODUCT-SELECTION.md)
