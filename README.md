# CodeEditorView

A multiplatform code editor for **macOS 15** and **iOS 18**.

Use it from SwiftUI, or drive the same engine through `EditorController` on AppKit and UIKit. Syntax highlighting is powered by Tree-sitter via optional language products (see **Products** below).

## Features

- **Editing** — multi-cursor and column selection, undo/redo, indent/outdent, comment toggle, move line, auto-pairs, drag & drop
- **Highlighting** — Tree-sitter languages and query-based themes; override with custom highlight providers when needed
- **Find & replace** — in-editor find panel, match navigation, replace current / all
- **Completions** — suggestion UI with an app-supplied `CodeSuggestionDelegate`
- **Jump to definition** — ⌘-hover / ⌘-click (macOS) or long-press (iOS) via `JumpToDefinitionDelegate`
- **Folding** — gutter ribbon and inline fold placeholders
- **Minimap** — optional scrollable overview of the document
- **Line annotations** — trailing severity chips and expandable message cards (host-supplied diagnostics; no built-in LSP)
- **Chrome** — line numbers, reformatting guide, invisible characters, themes

## Requirements

| | |
|---|---|
| Swift | 6 |
| Platforms | macOS 15+, iOS 18+ |
| Xcode | 16+ |

## Installation

Add the package in Xcode, or declare it in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ZegJoker/CodeEditorView.git", from: "0.1.0")
]
```

Link the products you need (see **Products**).

## Products

| Product | Role |
|---|---|
| **CodeEditorView** | Embeddable editor UI (SwiftUI / AppKit / UIKit). No grammar C targets. |
| **CodeEditorCore** | Platform-neutral document, selection, undo, formation, events. |
| **CodeEditorLanguageSupport** | Open `LanguageID`, definitions, registry, highlight contracts. |
| **CodeEditorTreeSitter** | Generic Tree-sitter lifecycle + highlight provider (no grammars). |
| **CodeEditorLanguageSwift** | Swift grammar + queries (pilot single-language pack). |
| **CodeEditorLanguageJSON** | JSON grammar + queries (pilot). |
| **CodeEditorLanguages** | Convenience umbrella: all grammars + `bootstrap()`. |

**Typical compositions**

```swift
// Small editor, no syntax highlighting
.product(name: "CodeEditorView", package: "CodeEditorView")

// Swift syntax only (call CodeEditorLanguageSwift.register() once at launch)
.product(name: "CodeEditorView", package: "CodeEditorView"),
.product(name: "CodeEditorLanguageSwift", package: "CodeEditorView")

// Full catalog (call CodeEditorLanguages.bootstrap() once, or import and use catalog APIs)
.product(name: "CodeEditorView", package: "CodeEditorView"),
.product(name: "CodeEditorLanguages", package: "CodeEditorView")
```

`CodeEditorView` re-exports Core, LanguageSupport, and TreeSitter for a simple `import CodeEditorView` call site.

## Quick start

```swift
import SwiftUI
import CodeEditorView
import CodeEditorLanguages // or CodeEditorLanguageSwift

struct EditorScreen: View {
    init() {
        // Install parsers/queries once per process (umbrella or individual packs).
        CodeEditorLanguages.bootstrap()
        // Alternatively: CodeEditorLanguageSwift.register()
    }

    @State private var text = """
    func hello() {
        print("hi")
    }
    """
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorState = EditorState()

    var body: some View {
        CodeEditor(
            text: $text,
            selection: $selection,
            editorState: $editorState,
            configuration: EditorConfiguration(
                appearance: .init(theme: .default, wrapLines: true),
                behavior: .init(isEditable: true, indentOption: .spaces(count: 4)),
                peripherals: .init(
                    showGutter: true,
                    showMinimap: false,
                    showReformattingGuide: true,
                    showFoldingRibbon: true
                )
            ),
            language: .swift
        )
        .frame(minHeight: 300)
    }
}
```

Flat `EditorConfiguration` initializers (for example `wrapLines:`, `showGutter:`) remain available for simple call sites.

Pass `highlightProviders:` to replace the default Tree-sitter highlighter, or wire `completionDelegate` / `jumpToDefinitionDelegate` on `CodeEditor` for IDE-style features.

Architecture notes for the modular split live under `Docs/Architecture/`. Run `scripts/check-product-isolation.sh` to verify dependency allowlists.

## Configuration

`EditorConfiguration` is grouped into four sections:

| Section | Controls |
|---|---|
| `appearance` | Theme, font, line height, wrap, tab width, bracket emphasis |
| `behavior` | Editable / selectable, indent style, reformat column |
| `layout` | Content insets, line-break strategy |
| `peripherals` | Gutter, minimap, folding ribbon, reformatting guide, invisibles |

## Programmatic API

`EditorController` is the shared model used by both platform views:

```swift
let controller = EditorController(text: source, configuration: .init())

// Multi-cursor
controller.setSelectedRanges([
    NSRange(location: 0, length: 0),
    NSRange(location: 10, length: 0),
])
controller.insertText("x")

// Find / replace
controller.showFindPanel(mode: .find)
controller.setFindQuery("print")
controller.findNext()

// Completions (app-supplied)
controller.completionDelegate = myCompletionDelegate
controller.showCompletions()

// Jump to definition (app-supplied)
controller.jumpToDefinitionDelegate = myJumpDelegate
controller.jumpToDefinition()

// Line annotations (host-supplied diagnostics)
controller.setAnnotations([
    LineAnnotation(
        line: 2,
        column: 4,
        severity: .error,
        message: "Missing return",
        detail: "Function is expected to return 'Int'."
    ),
    LineAnnotation(line: 5, severity: .warning, message: "Unused result"),
])
// controller.clearAnnotations()

// Transient emphasis (outline / fill / underline)
controller.emphasis.add(
    Emphasis(range: NSRange(location: 0, length: 4), style: .outline, flash: true)
)

// Text change stream
Task {
    for await value in controller.textChanges {
        print("changed:", value.count)
    }
}
```

### Shortcuts and gestures

| | macOS | iOS |
|---|---|---|
| Multi-cursor | Option-click adds a caret; Escape collapses | Multi-touch / `addCursor(at:)` |
| Column select | Option-Shift drag | `applyColumnSelection` API |
| Jump to definition | ⌘-hover outline, ⌘-click (or ⌃⌘J) | Long-press on an identifier |
| Indent | Tab / ⇧Tab · ⌘] / ⌘[ | Same |
| Comment | ⌘/ | ⌘/ |
| Move line | ⌥↑ / ⌥↓ | ⌥↑ / ⌥↓ |
| Auto-pairs | `()[]{}""` with skip-over | Same |

## Architecture

| Layer | Responsibility |
|---|---|
| `CodeEditor` | SwiftUI bindings and configuration |
| `AppKitEditorView` / `UIKitEditorView` | Input, drawing, scrolling, accessibility |
| `EditorController` | Document, layout, selection, undo, find, folds, annotations, streams |
| Core | Line index, typesetter, layout engine, highlighting, selection |

## Demo

A small SwiftUI host lives under `Examples/CodeEditorViewDemo`:

```bash
cd Examples/CodeEditorViewDemo
# Open the package in Xcode, or depend on it from an app target.
```

## Products and dependencies

| Product | Role |
|---|---|
| `CodeEditorView` | Editor UI and highlight orchestration |
| `CodeEditorLanguages` | Language registry, vendored Tree-sitter parsers, highlight queries |

External packages:

- [TextStory](https://github.com/ChimeHQ/TextStory) — text mutations and inverses
- [swift-collections](https://github.com/apple/swift-collections)
- [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter) — incremental parsing

Parsers are vendored under `Grammars/src/`; highlight queries live under `Sources/CodeEditorLanguages/Resources/`. Refresh them with `scripts/update-grammars.sh` (see `scripts/grammars.tsv`).

## License

MIT — see [LICENSE](LICENSE).
