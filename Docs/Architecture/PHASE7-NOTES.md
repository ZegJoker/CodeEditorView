# Phase 7 notes — workbench

## Minimal host

```swift
let workspace = try await Workspace.local(rootDirectories: [projectURL])
let model = WorkbenchModel(workspace: workspace)
// In App:
WorkbenchView(model: model)
    .frame(minWidth: 900, minHeight: 600)
```

## Hide chrome

```swift
var config = WorkbenchConfiguration()
config.showsInspector = false
config.showsUtilityArea = false
config.showsActivityBar = false
let model = WorkbenchModel(workspace: workspace, configuration: config)
```

## Custom contribution

```swift
final class MyInspector: WorkbenchContribution {
    let id = "app.inspector"
    let slot: WorkbenchSlot = .inspector
    let priority = 50
    let title = "Details"
    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(Text("Hello"))
    }
}
model.contributionRegistry.register(MyInspector())
```

## Open Quickly / Command Palette

- Toolbar buttons or `model.presentOpenQuickly()` / `model.presentCommandPalette()`
