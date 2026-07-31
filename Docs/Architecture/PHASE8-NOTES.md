# Phase 8 notes — Workbench integration

## Goal

Production workbench lifecycle, multi-window restoration, contribution isolation, focus/command routing, accessibility chrome, and tooling failure surfaces — without private host assembly knowledge.

## Isolation

`CodeEditorWorkbench` still **must not** depend on LSP / Search / Terminal / SourceControl / Languages (enforced by `check-product-isolation.sh`).

Tooling is integrated via **`WorkbenchToolingSurface`** descriptors that hosts update; FullWorkbench (or any host) wires real providers.

## Ownership

```
WorkbenchModel (lifecycle owner)
  ├─ Workspace
  ├─ WorkbenchWindowRegistry (multi-window chrome)
  ├─ WorkbenchContributionRegistry (descriptors + fault isolation)
  ├─ WorkbenchToolingSurfaceRegistry
  ├─ OpenQuicklyModel → WorkspaceIndexService (cancellable)
  ├─ CommandDispatcher + focus routing
  └─ WorkbenchHostBuilder (host entry)
```

## Deliverables

| Item | Status |
|---|---|
| Lifecycle phases (`creating`→`active`→`background`→`restoring`→`tearingDown`) | Done |
| Multi-window registry + chrome restore | Done |
| `WorkbenchRestorationState` encode/decode | Done |
| Contribution descriptors + `makeBodyIsolated` / fault UI | Done |
| Focus targets + command enablement validation | Done |
| Indexed Open Quickly (`FileTreeIndexService`) | Done |
| A11y IDs, L10n keys, reduced-motion animations | Done |
| Tooling failure banners (protocol-neutral) | Done |
| `WorkbenchHostBuilder` | Done |
| Contribution stress + multi-window + fault isolation tests | Done |

## Host usage

```swift
let model = try WorkbenchHostBuilder()
    .workspace(workspace)
    .configuration(.xcodeLike)
    .addToolingSurface(WorkbenchToolingSurface(
        id: "lsp",
        kind: .languageService,
        title: "Language Server",
        status: .ready
    ))
    .build()

// Host on failure:
model.toolingSurfaces.setStatus(id: "lsp", status: .failed(message: "exited"))

// Multi-window:
let w2 = model.createWindow(title: "Second")
model.focusWindow(w2.id)

// Restore:
let data = try model.encodeRestoration()
// … later …
model.applyRestoration(try WorkbenchRestoration.decode(data))
```

## Gate evidence

| Check | Result |
|---|---|
| `swift test --filter CodeEditorWorkbench` | See CI / local run |
| Multi-window create/restore | `WorkbenchLifecycleTests` |
| Contribution fault isolation | `ContributionIsolationTests` |
| Tooling failure isolation | `ToolingSurfaceTests` |
| Open Quickly index + cancel generation | `OpenQuicklyIndexTests` |
| Host builder | `HostBuilderTests` |
| Product isolation | Workbench forbids LSP/Terminal/SCM deps |

## Residual

- XCUITest VoiceOver / Dynamic Type screenshots  
- Full menu key-equivalent matrix on macOS AppKit host  
- SceneStorage bridge for SwiftUI multi-scene apps  
- Outline/search contributions beyond Open Quickly index  

## Related

- Phase 7 Tasks / Terminal / SCM  
- Phase 9 Extension author API  
