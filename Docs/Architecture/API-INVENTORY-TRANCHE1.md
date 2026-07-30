# API / module inventory — tranche 1 baseline

Captured on branch `feat/modular-framework-tranche-1` before modular splits land.

## Public products (pre-change)

| Product | Target | Notes |
|---|---|---|
| `CodeEditorView` | `CodeEditorView` | Embeddable editor; depends on full `CodeEditorLanguages` |
| `CodeEditorLanguages` | `CodeEditorLanguages` | All grammar targets + query resources |

## External dependencies

- `TextStory` ≥ 0.9.0
- `swift-collections` ≥ 1.1.0
- `swift-tree-sitter` ≥ 0.25.0

## View-layer files importing `CodeEditorLanguages`

- `Sources/CodeEditorView/EditorController.swift`
- `Sources/CodeEditorView/SwiftUI/CodeEditor.swift`
- `Sources/CodeEditorView/SwiftUI/EditorRepresentable.swift`
- `Sources/CodeEditorView/Core/Highlighting/TreeSitter/TreeSitterHighlightProvider.swift`

## Closed language catalog

- `TreeSitterLanguageID` — closed enum (`Sources/CodeEditorLanguages/TreeSitterLanguageID.swift`)
- Central C parser switch — `CodeLanguage.languagePointer(for:)` in `CodeLanguage.swift`

## Core areas targeted for `CodeEditorCore` (Phase 2)

| Path | Role |
|---|---|
| `Core/Document/*` | Buffer / attributed store |
| `Core/Index/*` | Line index |
| `Core/Selection/*` | Multi-range selection |
| `Core/Undo/*` | Undo coordinator |
| `Core/Formation/*` | Indent / structure commands / filters |
| `Core/Events/*` | Editor events |

## Test baseline

- **219** tests in **57** suites — all passed (`swift test`, ~11s)
- Suites under `Tests/CodeEditorViewTests` (51 files) + `Tests/CodeEditorLanguagesTests` (3 files)

## Import allowlist targets (to enforce)

See `ADR-001-dependency-direction.md`.
