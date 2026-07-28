# CodeEditorView

A multiplatform **code text editor** for **iOS 18** and **macOS 15**, with a platform-agnostic layout core, AppKit/UIKit hosts, and SwiftUI wrappers.

Built with **structured concurrency** and **Observation** (`@Observable` + `AsyncStream`). **No Combine.**

> Original implementation inspired by the product goals of [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView); not a port or copy of that project.

## Status

**Phase 10 complete** — line folding (indent provider, collapse storage, gutter ribbon, placeholders) via `peripherals.showFoldingRibbon` on AppKit & UIKit. Phase 9 minimap; Phase 8 completions; Phase 7 find/replace; Phase 6 formation; Phase 5 tree-sitter.

## Requirements

- Swift 6
- iOS 18+ / macOS 15+
- Xcode 16+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/ZegJoker/CodeEditorView.git", from: "0.1.0")
]
```

## SwiftUI

```swift
import SwiftUI
import CodeEditorView

struct EditorScreen: View {
    @State private var text = "func hello() {\n    print(\"hi\")\n}\n"
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
                peripherals: .init(showGutter: true, showReformattingGuide: true)
            ),
            language: .swift // auto tree-sitter highlighting
        )
        .frame(minHeight: 300)
    }
}
```

Flat `EditorConfiguration` initializers (e.g. `wrapLines:`, `showInvisibleCharacters:`) still work for simple call sites. Pass custom `highlightProviders:` to override the default tree-sitter provider (e.g. `RegexHighlightProvider.swiftLike()`).

## Programmatic control

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
controller.setReplaceText("debugPrint")
controller.replaceCurrentMatch()

// Completions (app supplies CodeSuggestionDelegate)
controller.completionDelegate = myCompletionDelegate
controller.showCompletions()

// Emphasis (flash via Task/Clock)
controller.emphasis.add(
    Emphasis(range: NSRange(location: 0, length: 4), style: .outline, flash: true)
)

// Streams
Task {
    for await value in controller.textChanges {
        print("changed:", value.count)
    }
}
```

### Platform tips

| Feature | macOS | iOS |
|---|---|---|
| Multi-cursor | Option-click adds caret; Escape collapses | Multi-touch tap / `addCursor(at:)` |
| Column select | Option+Shift drag | Use `applyColumnSelection` API |
| Drag & drop | Drop string onto view | UIDrag / UIDrop interactions |
| Invisibles | `showInvisibleCharacters` | same |
| Indent | Tab / ⇧Tab · ⌘] / ⌘[ | Tab / ⇧Tab · ⌘] / ⌘[ |
| Comment | ⌘/ | ⌘/ |
| Move line | ⌥↑ / ⌥↓ | ⌥↑ / ⌥↓ |
| Auto-pairs | `()[]{}""` skip-over | same |

## Architecture

| Layer | Role |
|---|---|
| `CodeEditor` (SwiftUI) | Bindings + configuration |
| `AppKitEditorView` / `UIKitEditorView` | Platform input, drawing, scroll, a11y, DnD |
| `EditorController` | Document, layout, multi-selection, undo, emphasis, streams |
| Core | `LineIndex`, `Typesetter`, `LayoutEngine`, `SelectionEngine`, attachments |

## Example

See `Examples/CodeEditorViewDemo` for a small SwiftUI demo package.

```bash
cd Examples/CodeEditorViewDemo
# Open in Xcode or wire as a local package dependency of an app target.
```

## Dependencies

- [TextStory](https://github.com/ChimeHQ/TextStory) — text mutations / inverses
- [swift-collections](https://github.com/apple/swift-collections)
- [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter) — incremental parsing / queries
- **CodeEditorLanguages** vendors multiplatform C grammars under `Grammars/src/` (no CodeEditLanguages binary container) and query files under `Sources/CodeEditorLanguages/Resources/tree-sitter-{name}/` (same `.scm` layout as CodeEditLanguages)

### Products

| Product | Role |
|---|---|
| `CodeEditorView` | Editor UI + highlight orchestration |
| `CodeEditorLanguages` | Full language registry (CEL-aligned), vendored parsers, `tree-sitter-*` query resources |

Refresh grammars with `scripts/update-grammars.sh` (see `scripts/grammars.tsv`).

## Prior art

- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) (MIT) — conceptual inspiration
- [TextStory](https://github.com/ChimeHQ/TextStory)

## License

MIT — see [LICENSE](LICENSE).
