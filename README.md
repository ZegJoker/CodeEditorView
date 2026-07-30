# CodeEditorView

A multiplatform code editor for **macOS 15** and **iOS 18**, shipped as a modular Swift package.

Use it from SwiftUI, or drive the same engine through `EditorController` on AppKit and UIKit. Optional products add workspace/workbench shells, language services, LSP, extensions, search, tasks, terminal, and source control.

## Features

- **Editing** — multi-cursor and column selection, undo/redo, indent/outdent, comment toggle, move line, auto-pairs
- **Highlighting** — Tree-sitter via optional language packs
- **Find & replace** — in-editor find; workspace search product for multi-file
- **Completions / jump** — host delegates or language-service providers
- **Folding, minimap, annotations, themes** — editor chrome
- **Modular tooling** — workspace, workbench, LSP, extensions, SCM, tasks, terminal (link only what you need)

## Requirements

| | |
|---|---|
| Swift | 6 |
| Platforms | macOS 15+, iOS 18+ |
| Xcode | 16+ |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/ZegJoker/CodeEditorView.git", from: "1.0.0")
]
```

## Products

| Product | Stability | Role |
|---|---|---|
| **CodeEditorView** | Stable | Embeddable editor UI |
| **CodeEditorCore** | Stable | Document buffer, selection, undo |
| **CodeEditorDocuments** | Stable | Shared `TextDocument` / sessions |
| **CodeEditorLanguageSupport** | Stable | Language IDs, registry, highlight contracts |
| **CodeEditorTreeSitter** | Stable | Tree-sitter provider (no grammars) |
| **CodeEditorLanguageSwift** / **JSON** | Stable* | Single-language packs |
| **CodeEditorLanguages** | Stable* | All grammars + `bootstrap()` |
| **CodeEditorCommands** | Evolving | Commands & keybindings |
| **CodeEditorWorkspace** | Evolving | Multi-root workspace & edits |
| **CodeEditorWorkbench** | Evolving | Optional SwiftUI shell |
| **CodeEditorLanguageServices** | Evolving | Provider contracts & host |
| **CodeEditorSearch** | Evolving | Workspace search/replace |
| **CodeEditorTasks** | Evolving | Tasks & problem matchers |
| **CodeEditorExtensions** | Experimental | In-process extensions |
| **CodeEditorExtensionHost** | Experimental | Out-of-process extension host |
| **CodeEditorLSP** | Experimental | LSP client |
| **CodeEditorTerminal** | Experimental | Terminal sessions |
| **CodeEditorSourceControl** | Experimental | SCM providers / Git CLI |

\* Pack **registration** API is stable; grammar content is not versioned as API. See `Docs/Guides/API-STABILITY.md`.

## Compositions

```swift
// Small editor
.product(name: "CodeEditorView", package: "CodeEditorView"),
.product(name: "CodeEditorLanguageSwift", package: "CodeEditorView")

// Medium shell
// + CodeEditorWorkspace, CodeEditorWorkbench, CodeEditorCommands, CodeEditorLanguageServices

// Full tooling
// + CodeEditorSearch, CodeEditorTasks, CodeEditorTerminal, CodeEditorSourceControl
// + CodeEditorLSP / CodeEditorExtensions / CodeEditorExtensionHost as needed
```

Examples:

- `Examples/SmallEditor` — View + Swift pack  
- `Examples/CodeEditorViewDemo` — interactive demo  
- `Examples/FullWorkbench` — workbench + tooling linkage  

## Quick start

```swift
import SwiftUI
import CodeEditorView
import CodeEditorLanguageSwift

struct EditorScreen: View {
    init() { CodeEditorLanguageSwift.register() }

    @State private var text = "func hello() {}\n"
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorState = EditorState()

    var body: some View {
        CodeEditor(
            text: $text,
            selection: $selection,
            editorState: $editorState,
            configuration: .init(),
            language: .swift
        )
    }
}
```

## Documentation

| Resource | Location |
|---|---|
| Product selection | `Docs/Guides/PRODUCT-SELECTION.md` |
| Migration to 1.0 | `Docs/Guides/MIGRATION-1.0.md` |
| Extension authoring | `Docs/Guides/EXTENSION-AUTHORING.md` |
| API stability | `Docs/Guides/API-STABILITY.md` |
| API audit | `Docs/Guides/API-AUDIT.md` |
| Architecture ADRs | `Docs/Architecture/` |
| Changelog | `CHANGELOG.md` |

DocC landings ship with each library target under `Sources/*/Documentation.docc/`.

## Quality gates

```bash
swift test
scripts/check-product-isolation.sh
scripts/check-docs.sh
```

## License

See [LICENSE](LICENSE).
