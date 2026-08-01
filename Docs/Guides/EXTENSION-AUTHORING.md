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

## Language-server extensions (Phase 12)

Extensions return a **launch plan**; the host starts LSP and owns the connection. You never touch the socket.

```swift
import CodeEditorExtensionAPI

struct SwiftToolsLS: LanguageServerProvider {
    var serverIDs: [String] { ["sourcekit-lsp"] }

    func resolveLaunchPlan(
        serverID: String,
        context: LanguageServerResolveContext
    ) async throws -> LanguageServerLaunchPlan {
        // Prefer host-resolved worktree which / settings
        if let path = context.which("sourcekit-lsp") {
            return LanguageServerLaunchPlan(
                serverID: serverID,
                displayName: "SourceKit-LSP",
                languages: ["Swift"],
                command: path,
                environment: context.environmentValues,
                binarySource: .absolute(path: path),
                extensionID: context.extensionID
            )
        }
        return LanguageServerLaunchPlan(
            serverID: serverID,
            displayName: "SourceKit-LSP",
            languages: ["Swift"],
            command: "sourcekit-lsp",
            binarySource: .systemPath(name: "sourcekit-lsp"),
            extensionID: context.extensionID
        )
    }

    func transformCompletionLabel(_ item: CompletionLabelTransform) async -> CompletionLabelTransform {
        var item = item
        item.label = "sk:" + item.label
        return item
    }

    func transformSymbolLabel(_ item: SymbolLabelTransform) async -> SymbolLabelTransform {
        var item = item
        item.name = "sk:" + item.name
        return item
    }
}
```

Binary sources: `.systemPath`, `.worktreeRelative`, `.downloaded(url:digest:cacheKey:)`, `.npm(package:version:bin:)`, `.absolute` (elevated/tests), `.testFactory` (tests).

TOML seed:

```toml
[language_servers.sourcekit-lsp]
languages = ["Swift"]
command = "sourcekit-lsp"
# optional: download_url, download_digest, npm_package, npm_version, npm_bin, args
```

Host (`CodeEditorExtensionHost`):

- `LanguageServerResolveContextBuilder` fills platform, worktree which/env, settings, project metadata
- `LanguageServerLaunchPlanExecutor` validates, materializes via capability broker (process allowlist, download digest, npm), starts `LanguageServerPool`
- `LanguageServerCoordinator` maps languages → servers, restarts on settings/toolchain change
- Label hooks apply to completions **and** document/workspace symbols

## Debugger / DAP extensions (Phase 13)

Extensions return a **debug adapter launch plan**; the host owns the DAP socket (`CodeEditorDAP`).

```toml
[debug_adapters.lldb]
languages = ["Swift"]
command = "lldb-dap"
```

Implement `DebugAdapterProvider` / `DebugLocatorProvider` in the author API. Pre/post debug tasks reference host `TaskService` IDs. Reverse `runInTerminal` is host-handled via Terminal backends.

## MCP server extensions (Phase 13)

```toml
[mcp_servers.my-server]
command = "my-mcp"
transport = "stdio"
```

`MCPServerProvider` returns an `MCPServerLaunchPlan`. The host MCP client speaks initialize / tools / resources / prompts over stdio. Extensions do not get unbounded network access.

## Slash commands

Slash commands are **stable**. Use `SlashCommandProvider` with streaming chunks; the host sanitizes markdown and enforces argument size limits.

## Documentation indexing

`DocumentationIndexProvider` suggests packages and builds indexes; storage and quotas are host-owned (`DocumentationIndexService`).

## Compatibility labels

See `Docs/Architecture/CompatibilityProfile.toml` and `CompatibilityProfileLoader`. Do not document experimental or unsupported surfaces as stable.

## Shipping profiles (Phase 15)

Host apps select a profile; library code fails closed outside that matrix:

| Profile | Native helpers | Marketplace Wasm | Notes |
|---|---|---|---|
| direct-macos | Yes (trust-gated) | Yes | Broadest |
| mac-app-store | No | No | Bundled Wasm OK; data install |
| ios | No | No | LS via remote tooling |
| enterprise | Org-signed | Policy | Managed registry flags |
| test | Yes | Yes | CI / mocks |

See [APP-REVIEW.md](APP-REVIEW.md) and [PHASE15-NOTES](../Architecture/PHASE15-NOTES.md).

## Publishing packages (Phase 14)

```bash
# Generate publisher key
codeeditor-extension gen-key --out ./keys --key-id my-pub

# Package evidence (checksums + SPDX SBOM)
codeeditor-extension package --dir ./my-extension
codeeditor-extension sbom --dir ./my-extension
codeeditor-extension sign --dir ./my-extension \
  --private-key ./keys/ed25519.private --key-id my-pub --subject "Example Org"
codeeditor-extension verify --dir ./my-extension --keyring ./keyring.json

# Local store install / update / rollback / recover
codeeditor-extension install --dir ./my-extension --install-root ~/Library/Application\ Support/CodeEditor/extensions
codeeditor-extension update --id com.example.my-extension --dir ./my-extension --install-root ...
codeeditor-extension rollback --id com.example.my-extension --install-root ...
codeeditor-extension recover --install-root ...
codeeditor-extension revoke-check --dir ./my-extension --revocation ./revocation.json
```

- Installs use **immutable version directories**; updates never overwrite an existing version tree.
- User data lives under `data/{extension-id}/` and survives update/uninstall unless purge is requested.
- Empty keyrings **reject** signed packages (fail-closed) unless an explicit authoring escape hatch is set.
- Revoked package IDs or key IDs cannot install or activate (host store + orchestrator gate).
- Prefer `LICENSE` (or `license =` in `extension.toml`) and generated `sbom.spdx.json` for strict license policy.
- Migration JSON→TOML records structured telemetry under `.codeeditor/telemetry.ndjson` (no PII / no source bodies).

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
