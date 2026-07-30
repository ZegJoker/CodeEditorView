# Phase 9 notes — extension runtime

## Minimal host

```swift
import CodeEditorCommands
import CodeEditorExtensions
import CodeEditorLanguageServices

@MainActor
func makeRuntime() -> ExtensionRuntime {
    let commands = CommandRegistry()
    let keybindings = KeybindingRegistry()
    let languageServices = LanguageServiceRegistry()
    let services = ExtensionHostServices.makeFull(
        commands: commands,
        keybindings: keybindings,
        languageServices: languageServices,
        storageRoot: FileManager.default.temporaryDirectory.appendingPathComponent("ext-storage")
    )
    let env = HostEnvironment(
        apiVersion: .phase9API,
        capabilities: Set(HostCapability.allCases),
        grantedPermissions: [.presentUI, .readWorkspace, .writeWorkspace]
    )
    return ExtensionRuntime(environment: env, services: services)
}
```

## Register and activate

```swift
let runtime = makeRuntime()
await runtime.register(MyCommandExtension())
await runtime.fire(.startup)          // activates matching extensions
// or:
try await runtime.activate(id: "com.example.myext")
await runtime.deactivate(id: "com.example.myext")
```

## Authoring an extension

```swift
struct MyCommandExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "com.example.hello",
        displayName: "Hello",
        activationEvents: [.startup],
        requiredHostCapabilities: [.commands],
        requestedPermissions: []
    )

    func activate(in context: ExtensionContext) async throws {
        let command = await MainActor.run {
            EditorCommand(id: "com.example.hello.say", title: "Say Hello") { _ in
                // …
            }
        }
        if let commands = context.commands {
            context.track(await commands.registerAsync(command))
        }
    }
}
```

## Data-only bundle (`extension.json`)

```json
{
  "id": "com.example.theme",
  "displayName": "Example Theme",
  "version": "1.0.0",
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

## Workbench panel mapping (host-side)

Extensions register `PanelContribution` descriptors. Map them in the host:

```swift
for panel in await runtime.panelStore.all() {
    // model.contributionRegistry.register(
    //   HostPanelContribution(descriptor: panel) // implements WorkbenchContribution
    // )
}
```

## Isolation

```bash
scripts/check-product-isolation.sh
```

`CodeEditorExtensions` must not import View, Workbench, TreeSitter, LSP, or ExtensionKit.
