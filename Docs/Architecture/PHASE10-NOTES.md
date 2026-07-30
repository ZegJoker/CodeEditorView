# Phase 10 notes — LSP client

## Minimal host (test transport)

```swift
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLSP

let pool = LanguageServerPool()
await pool.registerTestFactory(id: "mock") {
    let pair = LSPTestTransport.makePair()
    let mock = MockLanguageServer(transport: pair.server)
    await mock.start()
    return pair.client
}

let definition = LanguageServerDefinition(
    id: "mock-ls",
    displayName: "Mock LS",
    languages: ["swift"],
    launch: .test(factoryID: "mock"),
    workspaceRootURIs: [DocumentURI(fileURL: projectRoot)]
)

let session = try await pool.server(for: definition)
let registry = LanguageServiceRegistry()
let registration = await LSPClientProviders.register(session: session, into: registry)

let sync = LSPDocumentSynchronizer(session: session)
await sync.open(document: textDocument, languageID: "swift")

// Push diagnostics
Task {
    for await event in await session.diagnosticsStream {
        // controller.applyLanguageDiagnostics(event.diagnostics)
    }
}

let host = LanguageServiceHost(registry: registry)
let completions = try await host.completions(
    for: CompletionRequest(
        document: textDocument.snapshot(),
        position: TextPosition(utf16Offset: caret),
        context: LanguageServiceContext(languageID: "swift", uri: textDocument.uri)
    ),
    currentVersion: { textDocument.version }
)
```

## Process transport (real server)

```swift
let definition = LanguageServerDefinition(
    id: "sourcekit",
    displayName: "SourceKit-LSP",
    languages: ["swift"],
    launch: .process(
        executable: URL(fileURLWithPath: "/usr/bin/sourcekit-lsp"),
        arguments: []
    ),
    workspaceRootURIs: [DocumentURI(fileURL: projectRoot)]
)
let session = try await pool.server(for: definition)
```

## Lifecycle

```swift
await session.shutdown()
try await session.restart()   // re-opens tracked documents
await pool.shutdownAll()
registration.dispose()
```

## Isolation

```bash
scripts/check-product-isolation.sh
```

`CodeEditorLSP` must not import View, Workbench, Extensions, TreeSitter, or UI frameworks.
