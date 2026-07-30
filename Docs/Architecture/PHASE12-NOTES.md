# Phase 12 notes — extension host

## Mock remote extension (tests / local)

```swift
import CodeEditorExtensionHost
import CodeEditorExtensions
import CodeEditorLanguageServices

let pair = MockRemoteExtensionTransport.makePair()
let ext = MyCodeEditorExtension() // Phase 9 CodeEditorExtension
let server = RemoteExtensionServer(extension: ext, transport: pair.remote)
await server.run()

let registry = LanguageServiceRegistry()
let services = ExtensionHostServices(languageServiceRegistry: registry)
let descriptor = RemoteExtensionDescriptor(
    id: ext.manifest.id,
    displayName: ext.manifest.displayName,
    manifest: ext.manifest,
    launch: .testFactory("mock")
)
let host = RemoteExtensionHost(
    environment: .full,
    services: services,
    discovery: StaticRemoteExtensionDiscovery(descriptors: [descriptor])
)
await host.registerTestFactory(id: "mock") { pair.host }
try await host.refreshDiscovery()
try await host.start(id: ext.manifest.id)

// LanguageServiceHost(registry: registry) now includes remote completion/hover/definition
```

## Manager model

```swift
let model = ExtensionManagerModel(host: host)
await model.reload()
try await model.toggle(id: someID)
```

## Process launch

```swift
let descriptor = RemoteExtensionDescriptor(
    id: "com.example.ext",
    displayName: "Example",
    manifest: manifest,
    launch: .process(executable: helperURL, arguments: [])
)
```

## Policy

- Do **not** call private LaunchServices APIs to approve extensions.
- User approval and ExtensionKit installation remain host-app responsibilities.

## Isolation

```bash
scripts/check-product-isolation.sh
```
