# Phase 3 notes — versioned edits

## For event consumers

```swift
for await event in controller.editorEvents {
    switch event {
    case .willApplyEdit(let transaction, let snapshot):
        // snapshot.version is the pre-edit generation
        // transaction.changes are UTF-16 replacements
        break
    case .didApplyEdit(let applied):
        // applied.oldVersion / newVersion / inverse
        break
    case .selectionDidChangeDetailed(let change):
        // change.selections + change.version
        break
    case .willChangeText, .textDidChange, .selectionDidChange:
        // legacy no-payload cases (still emitted)
        break
    }
}
```

## Lifecycle observers

```swift
final class MyObserver: EditorLifecycleObserver {
    func editorWillApply(_ transaction: EditTransaction, snapshot: DocumentSnapshot) { … }
    func editorDidApply(_ result: AppliedEditTransaction) { … }
}

controller.setLifecycleObservers([observer])
```

Legacy `setCoordinators` continues to work unchanged.

## Version policy

- Starts at `0`
- Every content transaction increments by 1
- Undo/redo also increment (monotonic)
- Syntax attribute paints do not increment
