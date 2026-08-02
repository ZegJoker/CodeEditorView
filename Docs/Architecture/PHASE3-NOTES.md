# Phase 3 notes — Native editor input & layout (complete)

## Goal

Genuinely usable AppKit/UIKit editor input, off-main Tree-sitter, virtualized layout/a11y, and performance signposts.

## Exit evidence

| Criterion | Evidence |
|---|---|
| Marked text separate from undo spam | `MarkedTextSession`, `EditorController.applyMarkedText(registerUndo: false)`, `ControllerMarkedTextTests` |
| AppKit replacementRange | `AppKitEditorView.insertText(_:replacementRange:)` |
| Grapheme delete | `deleteBackward` uses `TextOffsetSemantics.graphemeBoundaryBefore`; `GraphemeDeleteMatrixTests` |
| Word subword | `WordNavigationMode.codeSubword`, `WordSubwordNavigationTests` |
| Drag move | `performDragOperation` → `moveText` for internal move; `DragMoveTransactionTests` |
| Text services policy | `EditorTextServicesPolicy` on `EditorConfiguration.Behavior` |
| Tree-sitter DI | `TreeSitterLanguageRuntime` actor + lock box; no `nonisolated(unsafe)` in TreeSitter module |
| Layout cache | `cachedMaxLineWidth` / `invalidateMaxLineWidthCache` |
| A11y virtualized | `EditorAccessibility.virtualizedValueText`; length O(viewport) |
| Signposts | `EditorSignposts` / `EditorPerformanceHarness` |
| IME/host | Phase 1 iOS/macOS example hosts; unit matrix suites |

## Defects closed

UI-001…UI-009, TS-001, IOS-001 (reverified).

## Verify

```bash
swift test --filter 'MarkedTextSessionTests|WordSubword|ControllerMarked|GraphemeDelete|DragMove|AccessibilityVirtual|PerformanceHarness'
rg 'nonisolated\(unsafe\)' Sources/CodeEditorTreeSitter  # empty
```
