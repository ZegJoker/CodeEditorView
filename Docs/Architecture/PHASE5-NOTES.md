# Phase 5 notes — commands

## Execute by ID

```swift
let controller = EditorController(text: source)
try controller.executeCommand(BuiltInCommandID.indent)
try controller.executeCommand("codeeditor.find.show")
```

## Custom command

```swift
let dispatcher = controller.commandDispatcher!
let token = dispatcher.commands.register(
    EditorCommand(id: "app.format", title: "Format Document", category: .edit) { ctx in
        try ctx.editor.perform(.indent) // or host logic
    }
)
// later
token.dispose()
```

## Keybinding overrides

```swift
let overrides = [
    KeybindingOverride(
        commandID: BuiltInCommandID.indent,
        keybinding: Keybinding(key: "i", modifiers: .command),
        source: .user
    )
]
let token = dispatcher.keybindings.applyOverrides(overrides)
```

## Conflict order

user > workspace > host > extension > built-in → higher priority → lower CommandID string.

## Palette

```swift
CommandPaletteView(
    model: CommandPaletteModel(),
    dispatcher: controller.commandDispatcher!,
    context: controller.makeCommandContext()
)
```
