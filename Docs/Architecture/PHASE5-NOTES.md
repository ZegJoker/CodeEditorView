# Phase 5 notes — Editor view façade and UI quality

## Goal

Reference workflows pass; public façade shrinks and is documented; IME/a11y/theme/lifecycle improved with tests.

## Ownership model

```
TextDocument (versioned text + undo; attribute paints do not bump version)
  └─ EditorController
       ├─ document: DocumentStore (shared store or session-local mirror)
       ├─ layout / selection / highlighter (revision-aware; cancel on disappear)
       ├─ platform host (AppKitEditorView / UIKitEditorView)
       └─ SwiftUI CodeEditor bindings (text, selection, EditorState)
```

Remote multi-controller edits: `EditorController+SharedDocument` + document event stream.  
Highlight tasks stamp generation/version and drop stale results (`Highlighter`).

## Deliverables

| Item | Status |
|---|---|
| `VIEW-PUBLIC-API.md` allowlist | Done |
| Demote Rendering/* + CursorBlinkController to `package` | Done |
| `EditorAccessibility` helpers + controller surfaces | Done |
| AppKit/UIKit a11y label/value/hint improvements | Done |
| UIKit real marked-text range composition | Done |
| `EditorTheme.tokenOverrides` / `resolve(token:)` / `applyTokenMap` | Done |
| `Highlighter.cancelPendingWork` + disappear cancel | Done |
| Reference workflow + IME composition tests | Done |

## Gate evidence

| Check | Result |
|---|---|
| `swift test --filter CodeEditorView` | **204 tests / 55 suites — passed** (includes reference workflows) |
| Type/select/undo, find, fold smoke, lifecycle, a11y, theme tokens, IME model | Pass |
| Isolation | unchanged product graph |

### Full-package note

A full `swift test` of the entire package can still hit intermittent parallel-suite instability (observed SIGSEGV / Dictionary index trap under high concurrency). View-filtered suite and isolated suites are green. Prefer `swift test --filter CodeEditorView` for View gate evidence; CI should keep product isolation jobs.

## Residual / manual

- XCUITest / screenshot goldens across scale and Dynamic Type  
- Full VoiceOver line-oriented tree for folds/diagnostics  
- UIKit marked-text selection *within* composition range  
- Further façade demotion of layout/typeset types (kept public for existing tests)  
- iOS Simulator interactive QA checklist  

## Related

- Phase 6: LanguageServices + LSP  
- Phase 9: Zed theme contribution import into `tokenOverrides`  
