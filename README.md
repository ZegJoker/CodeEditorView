# CodeEditorView

> **Pre-alpha.** Public APIs, package layout, extension manifests, and runtime behavior may change.
> Downloadable native/Wasm extensions, terminal UI, LSP/DAP integrations, and full workbench features
> are experimental and **not** security- or compatibility-qualified. See `Docs/Architecture/DEFECTS.md`.

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
| **CodeEditorView** | Pre-alpha | Embeddable editor UI (iOS input incomplete) |
| **CodeEditorCore** | Pre-alpha | Document buffer, selection, undo |
| **CodeEditorDocuments** | Pre-alpha | Shared `TextDocument` / sessions |
| **CodeEditorLanguageSupport** | Pre-alpha | Language IDs, registry, highlight contracts |
| **CodeEditorTreeSitter** | Pre-alpha | Tree-sitter provider (no grammars) |
| **CodeEditorLanguageSwift** / **JSON** | Pre-alpha* | Single-language packs |
| **CodeEditorLanguages** | Pre-alpha* | All grammars + `bootstrap()` |
| **CodeEditorCommands** | Pre-alpha | Commands & keybindings |
| **CodeEditorWorkspace** | Pre-alpha | Multi-root workspace & edits |
| **CodeEditorWorkbench** | Pre-alpha | Optional SwiftUI shell (placeholders remain) |
| **CodeEditorLanguageServices** | Pre-alpha | Provider contracts & host |
| **CodeEditorSearch** | Pre-alpha | Workspace search/replace |
| **CodeEditorTasks** | Pre-alpha | Tasks & problem matchers |
| **CodeEditorExtensionAPI** | Experimental | Author SDK (`extension.toml`, protocols) |
| **CodeEditorExtensionProtocol** | Experimental | CBOR wire protocol for host ↔ guest |
| **CodeEditorExtensionGuest** | Experimental | Native helper guest runtime |
| **CodeEditorWasmEngine** | Experimental | Portable Wasm engine protocol + limits |
| **CodeEditorWasmEngineWasmKit** | Simulation only | **Does not execute Wasm bytecode** (WASM-001) |
| **CodeEditorExtensionWasmGuest** | Experimental | Cooperative core-Wasm guest glue |
| **CodeEditorExtensions** | Experimental | In-process runtime / package manager |
| **CodeEditorExtensionHost** | Experimental | Multi-driver host, broker, signing, Wasm |
| **CodeEditorLSP** | Experimental | LSP client |
| **CodeEditorTerminal** | Experimental | Terminal — Ghostty migration required (TER-001) |
| **CodeEditorSourceControl** | Experimental | SCM providers / Git CLI |
| **CodeEditorDAP** | Experimental | Debug Adapter Protocol client |

\* Language pack APIs are pre-alpha; grammar C sources are generated/local (`Grammars/`). See `Docs/Guides/API-STABILITY.md`.

## Compositions

```swift
// Small editor
.product(name: "CodeEditorView", package: "CodeEditorView"),
.product(name: "CodeEditorLanguageSwift", package: "CodeEditorView")

// Medium shell
// + CodeEditorWorkspace, CodeEditorWorkbench, CodeEditorCommands, CodeEditorLanguageServices

// Full tooling
// + CodeEditorSearch, CodeEditorTasks, CodeEditorTerminal, CodeEditorSourceControl
// + CodeEditorLSP / CodeEditorExtensionAPI / CodeEditorExtensions / CodeEditorExtensionHost as needed
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
