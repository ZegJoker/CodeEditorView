# CodeEditorView public API allowlist (Phase 5)

Intentional host-facing surface. Implementation types should use `package` or `internal`.

## Entry points

| Symbol | Role |
|---|---|
| `CodeEditor` | SwiftUI wrapper |
| `SharedCodeEditor` | Multi-session SwiftUI |
| `EditorRepresentable` | UIViewRepresentable / NSViewRepresentable bridge |
| `EditorController` | Headless / host-owned model |
| `AppKitEditorView` / `UIKitEditorView` | Native embedding |

## Configuration & state

- `EditorConfiguration` (+ nested Appearance/Behavior/Layout/Peripherals)
- `EditorTheme` (+ token overrides / `resolve(token:)`)
- `EditorState`, `CursorPosition`
- `HorizontalEdgeInsets`, `LineBreakStrategy`, `PlatformDefaults` / platform font-color aliases

## Host integration

- `EditorCoordinator`, `EditorLifecycleObserver`
- `FindSession`, `FindMethod`, `FindPanelMode`, `FindEngine` (logic)
- `CodeSuggestionDelegate`, `CodeSuggestionEntry`, `CompletionSession`, `SuggestionTrigger`
- `JumpToDefinitionDelegate`, `JumpToDefinitionLink` / model types used by hosts
- `LineAnnotation`, `DiagnosticSeverity`, `LineAnnotationStore` (if hosts set annotations)
- Language-service adapters under `LanguageServices/` (Workbench)

## Package / implementation (not stable host API)

- `Rendering/*Renderer`, `SFSymbolDrawing`
- `CursorBlinkController`, `MinimapRunBuilder` (geometry may stay public)
- Layout/typeset internals not required by hosts (`TextLine`, `LineFragment`, etc. may remain public for tests — prefer package when tests allow)
- `FindPanelBridge` (SwiftUI chrome internal)

## Re-exports

`CodeEditorView` re-exports Core, Documents, Commands, LanguageSupport, TreeSitter for convenience. Stability of those products is defined by their own gates.
