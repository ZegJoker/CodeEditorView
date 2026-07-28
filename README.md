# CodeEditorView

A multiplatform **code text editor** for **iOS 18** and **macOS 15**, with a platform-agnostic layout core, AppKit/UIKit hosts, and SwiftUI wrappers.

Built with **structured concurrency** and **Observation** (`@Observable` + `AsyncStream`). **No Combine.**

> Original implementation inspired by the product goals of [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView); not a port or copy of that project.

## Status

**Phase 2 complete** — multi-cursor, column selection, attachments, emphasis, invisible characters, drag-and-drop, accessibility baseline, localized layout invalidation, and platform polish.

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

    var body: some View {
        CodeEditor(
            text: $text,
            selection: $selection,
            configuration: EditorConfiguration(
                wrapLines: true,
                isEditable: true,
                showInvisibleCharacters: false
            )
        )
        .frame(minHeight: 300)
    }
}
```

## Programmatic control

```swift
let controller = EditorController(text: source, configuration: .init())

// Multi-cursor
controller.setSelectedRanges([
    NSRange(location: 0, length: 0),
    NSRange(location: 10, length: 0),
])
controller.insertText("x")

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

## Prior art

- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) (MIT) — conceptual inspiration
- [TextStory](https://github.com/ChimeHQ/TextStory)

## License

MIT — see [LICENSE](LICENSE).
