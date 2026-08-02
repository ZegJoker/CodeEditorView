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
| Swift | 6.0 tools / 6.3 compiler (see `Docs/Architecture/TOOLCHAIN.md`) |
| Platforms | macOS 15+, iOS 18+ |
| Xcode | **26.4** (exact pin: `Docs/Architecture/XCODE.pin`) |
| Network | Only for SwiftPM remote dependencies on first resolve |

## Developer setup

```bash
git clone <repo>
cd CodeEditorView
swift package resolve
swift build --product CodeEditorCore
swift build --product CodeEditorLanguageSwift   # grammars are committed
swift test
```

Tree-sitter **C sources are committed** under `Packages/CodeEditorGrammars` (PKG-001). A clean clone does **not** require `./scripts/update-grammars.sh`. That script is a **maintainer** tool to refresh pins from upstream; after running it, commit the package sources and checksums.

Highlight query files (`.scm`) live under `Sources/CodeEditorLanguages/Resources/` and language-pack `Resources/`. Missing required queries surface as `LanguagePackError`.

**Stabilization program:** see `Docs/Architecture/PHASE0-NOTES.md`, `PHASE1-NOTES.md`, and ADRs 013–016.

**CI:** `.github/workflows/ci.yml` — hard format/WASI/Xcode pin, source-archive rehearsal, macOS/iOS example `xcodebuild test`, empty-cache resolve, product smoke, coverage, API baselines. Local: `./scripts/verify-local.sh`.

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
| **CodeEditorWorkbench** | Pre-alpha | Optional SwiftUI shell (navigators/schemes/models; not 1.0 Stable) |
| **CodeEditorLanguageServices** | Pre-alpha | Provider contracts & host |
| **CodeEditorSearch** | Pre-alpha | Workspace search/replace |
| **CodeEditorTasks** | Pre-alpha | Tasks & problem matchers |
| **CodeEditorExtensionAPI** | Experimental | Author SDK (`extension.toml`, protocols) |
| **CodeEditorExtensionProtocol** | Experimental | CBOR wire protocol for host ↔ guest |
| **CodeEditorExtensionGuest** | Experimental | Native helper guest runtime |
| **CodeEditorWasmEngine** | Experimental | Portable Wasm engine protocol + limits (+ LinkedGuest simulation path) |
| **CodeEditorWasmEngineWasmKit** | Experimental | Real WasmKit parse/instantiate/call (module bytes determine behavior) |
| **CodeEditorExtensionWasmGuest** | Experimental | Cooperative core-Wasm guest glue |
| **CodeEditorExtensions** | Experimental | In-process runtime / package manager |
| **CodeEditorExtensionHost** | Experimental | Multi-driver host, broker, signing, Wasm |
| **CodeEditorLSP** | Experimental | LSP client |
| **CodeEditorTerminal** | Experimental | Terminal — Ghostty migration required (TER-001) |
| **CodeEditorSourceControl** | Experimental | SCM providers / Git CLI |
| **CodeEditorDAP** | Experimental | Debug Adapter Protocol client |

\* Language pack APIs are pre-alpha; grammar C sources are committed in `Packages/CodeEditorGrammars`. See `Docs/Guides/API-STABILITY.md`.

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

- `Examples/macOS/CodeEditorMacExample` — Xcode 26 macOS host (`xcodebuild test`)
- `Examples/iOS/CodeEditoriOSExample` — Xcode 26 iOS host (`xcodebuild test`)
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
