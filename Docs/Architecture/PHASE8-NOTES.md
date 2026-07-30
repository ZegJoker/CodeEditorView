# Phase 8 notes — generic language services

## Minimal host

```swift
import CodeEditorLanguageServices

let registry = LanguageServiceRegistry()
let mock = MockLanguageSuite.sample()
await mock.register(in: registry)

let host = LanguageServiceHost(registry: registry)
let snapshot = document.snapshot()
let ctx = LanguageServiceContext(languageID: "swift", uri: document.uri)

let list = try await host.completions(
    for: CompletionRequest(
        document: snapshot,
        position: TextPosition(utf16Offset: caret),
        context: ctx
    ),
    currentVersion: { document.version }
)
```

## Register a custom provider

```swift
struct KeywordCompletions: CompletionProvider {
    let id: ProviderID = "app.keywords"
    let selector = DocumentSelector.languages("swift")
    let priority = 5

    func completions(for request: CompletionRequest) async throws -> CompletionList {
        CompletionList(items: [
            CompletionItem(label: "guard", kind: .keyword, insertText: "guard "),
        ])
    }
}

await registry.register(KeywordCompletions())
```

## Wire into the editor (optional)

```swift
// Retains adapters on the controller; replaces completion + jump delegates.
controller.installLanguageServices(host)

// Later:
let diagnostics = try await host.diagnostics(
    for: DocumentRequest(document: controller.textDocument.snapshot(), context: ctx),
    currentVersion: { controller.textDocument.version }
)
controller.applyLanguageDiagnostics(diagnostics)

controller.clearLanguageServices()
```

## Adapters without install hook

```swift
let completion = CompletionProviderDelegateAdapter(host: host, context: ctx)
controller.completionDelegate = completion
// Host must retain `completion` (weak on controller).

let jump = DefinitionProviderJumpAdapter(host: host, context: ctx)
controller.jumpToDefinitionDelegate = jump
```

## Isolation

```bash
scripts/check-product-isolation.sh
```

`CodeEditorLanguageServices` must not import View, Workbench, UI frameworks, TreeSitter, or LSP.
