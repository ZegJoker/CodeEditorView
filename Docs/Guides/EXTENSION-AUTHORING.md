# Extension authoring guide

Extensions contribute language features and data without forking the editor. Prefer **in-process** Swift types (Phase 9). Use **data-only** bundles for themes/snippets. Use **out-of-process** hosting (Phase 12) when crash isolation is required.

## Concepts

| Concept | Module |
|---|---|
| `ExtensionManifest`, permissions, activation | `CodeEditorExtensions` |
| `ExtensionRuntime` / `ExtensionContext` | `CodeEditorExtensions` |
| Registrars (commands, languages, language services, panels) | `CodeEditorExtensions` |
| Remote host + RPC | `CodeEditorExtensionHost` |

## In-process extension

```swift
import CodeEditorExtensions
import CodeEditorCommands
import CodeEditorLanguageServices

struct HelloExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "com.example.hello",
        displayName: "Hello",
        activationEvents: [.startup],
        requiredHostCapabilities: [.commands, .languageServices]
    )

    func activate(in context: ExtensionContext) async throws {
        let command = await MainActor.run {
            EditorCommand(id: "com.example.hello.say", title: "Say Hello") { _ in }
        }
        if let commands = context.commands {
            context.track(await commands.registerAsync(command))
        }
        // Register CompletionProvider via context.languageServices similarly
    }
}

// Host:
await runtime.register(HelloExtension())
await runtime.fire(.startup)
```

## Data-only bundle

`extension.json` (see PHASE9-NOTES):

```json
{
  "id": "com.example.theme",
  "displayName": "Theme",
  "activationEvents": ["startup"],
  "requiredHostCapabilities": ["themes"],
  "themes": [
    { "id": "midnight", "displayName": "Midnight", "tokens": { "keyword": "#c792ea" } }
  ]
}
```

```swift
let bundle = try DataExtensionLoader.load(from: directoryURL)
await runtime.register(DataExtensionLoader.makeExtension(from: bundle))
try await runtime.activate(id: bundle.manifest.id)
```

## Permissions

Request only what you need. Host grants the intersection. Panel registration requires `presentUI`. Storage paths cannot escape the extension sandbox without explicit policy.

## Out-of-process (remote)

```swift
let pair = MockRemoteExtensionTransport.makePair()
let server = RemoteExtensionServer(extension: myExt, transport: pair.remote)
await server.run()

// Host side: RemoteExtensionHost + testFactory returning pair.host
// Remote completion/hover/definition register into LanguageServiceRegistry
```

Production apps supply process or ExtensionKit transports; **do not** call private LaunchServices APIs to force-approve extensions (ADR-011).

## Do not

- Import `CodeEditorView` / SwiftUI from extension library code intended for headless hosts  
- Bypass `WorkspaceEdit` for multi-file edits  
- Assume experimental ExtensionHost RPC is stable across minors without pinning  

## Related

- PHASE9-NOTES, PHASE12-NOTES  
- ADR-008, ADR-011  
- [Product selection](PRODUCT-SELECTION.md)
