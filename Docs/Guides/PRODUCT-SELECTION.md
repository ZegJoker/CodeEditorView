# Product selection guide

Choose the smallest product set that matches your host. All products live in the same Swift package; link only what you need.

## Profiles

### Small editor (embed)

**Goal:** SwiftUI/AppKit text editor with optional syntax highlighting.

| Product | Required |
|---|---|
| `CodeEditorView` | yes |
| `CodeEditorLanguageSwift` (or `JSON` / `Languages`) | optional |

```swift
dependencies: [
  .package(url: "https://github.com/ZegJoker/CodeEditorView.git", from: "1.0.0")
]
// .product(name: "CodeEditorView", package: "CodeEditorView")
// .product(name: "CodeEditorLanguageSwift", package: "CodeEditorView")
```

Call `CodeEditorLanguageSwift.register()` (or `CodeEditorLanguages.bootstrap()`) once at launch if highlighting.

See `Examples/SmallEditor`.

### Medium IDE shell

**Goal:** Multi-file workspace + workbench chrome + commands.

| Product | Role |
|---|---|
| `CodeEditorView` | editors |
| `CodeEditorDocuments` | shared buffers (also via View) |
| `CodeEditorCommands` | palette / keybindings |
| `CodeEditorWorkspace` | roots, tabs, splits |
| `CodeEditorWorkbench` | shell UI |
| `CodeEditorLanguageServices` | provider contracts (optional until LSP/extensions) |

See `Examples/CodeEditorViewDemo` (editor-focused) and `Examples/FullWorkbench` (composition sketch).

### Language intelligence

Add one or both:

| Product | Role |
|---|---|
| `CodeEditorLSP` | process / test LSP client |
| `CodeEditorExtensions` | in-process providers |
| `CodeEditorExtensionHost` | multi-runtime host (built-in, native, Wasm, remote) |

Wire providers into `LanguageServiceRegistry`, then `EditorController.installLanguageServices` / adapters (Phase 8).

### Full tooling

| Product | Role |
|---|---|
| `CodeEditorSearch` | find/replace in files → `WorkspaceEdit` |
| `CodeEditorTasks` | build tasks + problem matchers |
| `CodeEditorTerminal` | headless terminal sessions |
| `CodeEditorSourceControl` | SCM provider + Git CLI |

None of these depend on each other; omit freely.

## Anti-patterns

- Linking `CodeEditorLanguages` when you only need Swift — use `CodeEditorLanguageSwift`.
- Importing View from headless tools/extensions — keep UI at the host edge.
- Depending on products without reading [API-STABILITY](API-STABILITY.md) tiers and scorecards.

## Related

- [API audit](API-AUDIT.md)
- [Migration](MIGRATION-1.0.md)
- [PHASE notes](../Architecture/)
