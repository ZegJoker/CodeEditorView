# ``CodeEditorView``

A multiplatform code text editor for iOS 18 and macOS 15.

## Overview

`CodeEditorView` provides a line-oriented code editor with:

- Shared layout core (line index, CoreText typesetter, viewport layout)
- Multi-range selection and multi-cursor editing
- Column selection (macOS Option-drag)
- Nested ``EditorConfiguration`` (appearance, behavior, layout, peripherals)
- ``EditorTheme``, line gutter, current-line highlight, reformatting guide
- Bracket pair emphasis via ``BracketMatcher``
- Syntax highlighting: ``HighlightProviding``, ``Highlighter``, ``RegexHighlightProvider``, ``TreeSitterHighlightProvider``
- Formation: Tab/Shift-Tab indent, newline auto-indent, auto-pairs, move lines, toggle comments
- Find & replace: ``FindEngine``, ``FindSession``, panel chrome, match emphasis
- Code completion: ``CodeSuggestionDelegate``, ``CodeSuggestionEntry``, floating list (AppKit + UIKit)
- Minimap overview: ``MinimapGeometry``, ``MinimapRunBuilder``, ``peripherals.showMinimap``
- ``EditorCoordinator`` injection (structured concurrency — no Combine)
- ``EditorState`` for cursors / find-panel bindings
- Emphasis overlays and invisible characters
- Text attachments
- AppKit / UIKit hosts and a SwiftUI ``CodeEditor`` wrapper
- `AsyncStream` event streams — no Combine

## Topics

### SwiftUI

- ``CodeEditor``
- ``EditorConfiguration``
- ``EditorController``
- ``EditorState``
- ``EditorTheme``
- ``EditorCoordinator``

### Highlighting

- ``HighlightProviding``
- ``HighlightRange``
- ``Highlighter``
- ``RegexHighlightProvider``
- ``TreeSitterHighlightProvider``
- ``RangeStore``
- ``StyledRangeContainer``
- ``CaptureName``

### Selection

- ``SelectionEngine``
- ``SelectionMode``
- ``TextRangeSelection``
- ``MultiRangeEdit``
- ``CursorPosition``

### Layout

- ``LayoutEngine``
- ``LineIndex``
- ``Typesetter``
- ``TextAttachment``
- ``AttachmentStore``
- ``GutterModel``

### Brackets & chrome

- ``BracketMatcher``
- ``BracketPairEmphasis``
- ``BracketPairs``
- ``IndentOption``
- ``TextFilters``
- ``StructureCommands``
- ``TextReplacement``

### Find & replace

- ``FindEngine``
- ``FindMethod``
- ``FindPanelMode``
- ``FindSession``
- ``FindPanelView``
- ``FindPanelBridge``
- ``EmphasisGroup``

### Completion

- ``CodeSuggestionDelegate``
- ``CodeSuggestionEntry``
- ``SimpleCodeSuggestion``
- ``CompletionSession``
- ``SuggestionTrigger``
- ``SuggestionImageColorToken``

### Minimap

- ``MinimapMetrics``
- ``MinimapGeometry``
- ``MinimapRunBuilder``
- ``MinimapBubbleRun``
- ``MinimapSnapshot``

### Emphasis & invisibles

- ``Emphasis``
- ``EmphasisManager``
- ``InvisibleCharactersDelegate``
