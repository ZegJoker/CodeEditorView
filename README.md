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
| Git + network | Required once to fetch Tree-sitter grammars (see below) |

## Developer setup (Tree-sitter grammars)

Vendored Tree-sitter **C sources are not checked into git** (they are large third-party generated code). They live under `Grammars/` after you generate them locally.

**Prerequisites:** `git`, network access to GitHub (and any grammar remotes listed in `scripts/grammars.tsv`).

```bash
# From the repository root:
./scripts/update-grammars.sh
```

This clones (or reuses a cache under `$TMPDIR/codeeditorview-grammars`) each grammar from `scripts/grammars.tsv` and materializes:

- `Grammars/src/<lang>/parser.c` (+ `scanner.c` / `scanner.cc` when present)
- `Grammars/src/<lang>/tree_sitter/*.h`
- `Grammars/src/<lang>/include/<lang>.h` (public `tree_sitter_*()` entry points)
- Shared `common/` bits for TypeScript / TSX / PHP / OCaml when upstream provides them (includes rewritten to local paths after flatten)

`Grammars/` is listed in `.gitignore`. Re-run the script after cloning the repo, when adding a language to `grammars.tsv`, or when you intentionally want newer upstream parsers.

**Stabilization program:** see `Docs/Architecture/PHASE0-NOTES.md`, `PHASE1-NOTES.md`, and ADRs 013–016 for the evidence-based Stable gate, platform capability profiles, and Swift-first extension platform direction.

**CI:** `.github/workflows/ci.yml` (macOS tests, iOS Simulator build, empty-cache resolve, product smoke, coverage, API baselines, WASI pin, isolation/docs). Local mirror: `./scripts/verify-local.sh`.

**When you need it**

| Goal | Need `./scripts/update-grammars.sh`? |
|---|---|
| Build/test **CodeEditorView** / Core / Workbench only | No |
| Build/test **CodeEditorLanguageSwift**, **JSON**, **CodeEditorLanguages**, language tests | **Yes** |
| Examples that call `CodeEditorLanguageSwift.register()` | **Yes** |

Highlight **query** files (`.scm`) remain in-repo under `Sources/CodeEditorLanguages/Resources/` and `Sources/CodeEditorLanguage*/` — only the C parser sources are generated.

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
# First-time / CI: materialize Tree-sitter C grammars before language tests
./scripts/update-grammars.sh

swift test
scripts/check-product-isolation.sh
scripts/check-docs.sh
```

## License

See [LICENSE](LICENSE).
