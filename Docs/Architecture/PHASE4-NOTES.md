# Phase 4 notes — shared documents

## Binding API (unchanged)

```swift
CodeEditor(text: $text, selection: $selection, editorState: $editorState, language: .swift)
```

Creates a private `TextDocument` under the hood.

## Shared document API

```swift
let document = TextDocument(text: source)
let sessionA = EditorSession(documentID: document.id)
let sessionB = EditorSession(documentID: document.id)

// Programmatic
let a = EditorController(document: document, session: sessionA, language: .swift)
let b = EditorController(document: document, session: sessionB, language: .swift)

// SwiftUI
SharedCodeEditor(document: document, session: sessionA, language: .swift)
// or
CodeEditor.shared(document: document, session: sessionB, language: .swift)
```

## Load / save

```swift
let files = LocalFileDocumentProvider()
try await document.load(from: files, uri: DocumentURI(fileURL: url))
try await document.save(using: files)

let memory = InMemoryDocumentProvider()
try await document.save(using: memory)
```

## External reload

```swift
try document.applyExternalContent(newText, policy: .reloadIfClean)
try document.applyExternalContent(newText, policy: .alwaysReload)
```

## Events

```swift
for await event in document.makeEventStream() {
    switch event {
    case .didApply(let applied): …
    case .dirtyStateDidChange(let dirty): …
    default: break
    }
}
```
