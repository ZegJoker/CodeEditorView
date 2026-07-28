# CodeEditorView

A multiplatform **code text editor** for **iOS 18** and **macOS 15**, with a platform-agnostic layout core, AppKit/UIKit hosts, and SwiftUI wrappers.

Built with **structured concurrency** and **Observation** (`@Observable` + `AsyncStream`). **No Combine.**

> This is an original implementation. Domain goals (line-oriented layout for large code documents, fast initial layout, custom drawing) are inspired by [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView); the code is not a port or copy of that project.

## Status

**MVP** — core editing, layout, selection, undo, SwiftUI bindings on both platforms. Multi-cursor, attachments, emphasis, and other advanced features are planned for later phases.

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
                isEditable: true
            )
        )
        .frame(minHeight: 300)
    }
}
```

## Programmatic control

```swift
let controller = EditorController(text: source, configuration: .init())
controller.insertText("x")
controller.undo()

Task {
    for await value in controller.textChanges {
        print("text changed:", value.count)
    }
}
```

## Architecture

| Layer | Role |
|---|---|
| `CodeEditor` (SwiftUI) | Bindings + configuration |
| `AppKitEditorView` / `UIKitEditorView` | Platform input, drawing, scroll |
| `EditorController` | Document, layout, selection, undo, streams |
| Core | `LineIndex`, `Typesetter`, `LayoutEngine`, `SelectionEngine` (no AppKit/UIKit UI frameworks beyond shared text types) |

## Dependencies

- [TextStory](https://github.com/ChimeHQ/TextStory) — text mutations / inverses
- [swift-collections](https://github.com/apple/swift-collections) — collections utilities (available for growth)

## Prior art

- [CodeEditTextView](https://github.com/CodeEditApp/CodeEditTextView) (MIT) — conceptual inspiration for line-based code editing
- [TextStory](https://github.com/ChimeHQ/TextStory) — mutation helpers

## License

MIT — see [LICENSE](LICENSE).

## Roadmap (post-MVP)

- Multi-cursor / multi-range editing
- Column selection
- Text attachments
- Emphasis / find highlights
- Invisible characters
- Drag and drop
- Accessibility expansion
- Localized layout invalidation (vs full rebuild)
