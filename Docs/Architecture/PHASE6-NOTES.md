# Phase 6 notes — workspace

## Headless open

```swift
let root = URL(fileURLWithPath: "/path/to/project")
let workspace = try await Workspace.local(rootDirectories: [root])

let uri = DocumentURI(fileURL: root.appendingPathComponent("Sources/App.swift"))
let (document, session, tab) = try await workspace.openInActivePane(uri: uri, preview: true)

// Split the active pane
_ = workspace.splitActivePane(axis: .horizontal)
```

## Lazy tree

```swift
let rootID = workspace.fileSystem.roots[0].id
let rootItem = WorkspaceItemID(rootID: rootID, path: "")
try await workspace.fileTree.expand(rootItem)
let children = try await workspace.fileTree.children(of: rootItem)
```

## Workspace edit

```swift
let service = WorkspaceEditService(workspace: workspace)
let edit = WorkspaceEdit(
    documentChanges: [
        DocumentChange(
            uri: document.uri,
            documentID: document.id,
            expectedVersion: document.version,
            transaction: .single(range: NSRange(location: 0, length: 0), replacement: "// hi\n")
        )
    ],
    fileOperations: [
        .createFile(uri: DocumentURI(fileURL: root.appendingPathComponent("Notes.md")), contents: "# Notes\n")
    ]
)
_ = try await service.apply(edit)
```

## Restoration

```swift
let data = try WorkspaceRestoration.encode(workspace)
// … persist data …
let state = try WorkspaceRestoration.decode(data)
let restored = try await Workspace.restore(from: state, fileSystem: fs)
```
