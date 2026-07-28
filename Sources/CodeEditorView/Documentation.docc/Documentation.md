# ``CodeEditorView``

A multiplatform code text editor for iOS 18 and macOS 15.

## Overview

`CodeEditorView` provides a line-oriented code editor with:

- Shared layout core (line index, CoreText typesetter, viewport layout)
- Multi-range selection and multi-cursor editing
- Column selection (macOS Option-drag)
- Emphasis overlays and invisible characters
- Text attachments
- AppKit / UIKit hosts and a SwiftUI ``CodeEditor`` wrapper
- Structured concurrency event streams — no Combine

## Topics

### SwiftUI

- ``CodeEditor``
- ``EditorConfiguration``
- ``EditorController``

### Selection

- ``SelectionEngine``
- ``SelectionMode``
- ``TextRangeSelection``
- ``MultiRangeEdit``

### Layout

- ``LayoutEngine``
- ``LineIndex``
- ``Typesetter``
- ``TextAttachment``
- ``AttachmentStore``

### Emphasis & invisibles

- ``Emphasis``
- ``EmphasisManager``
- ``InvisibleCharactersDelegate``
