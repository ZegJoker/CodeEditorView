# FullWorkbench

Reference host composition for the modular CodeEditorView package — an **Xcode-shaped** shell that wires optional products **outside** `CodeEditorWorkbench` (ADR isolation).

## Run

```bash
cd Examples/FullWorkbench
swift build -c debug
# or wrap as .app for key focus (see repo scripts pattern)
```

## What is composed

| Area | Product | UI |
|---|---|---|
| Shell | CodeEditorWorkbench | Docked navigator, tabs, utility split, status |
| Find navigator | CodeEditorSearch | Activity bar magnifying glass / Find mode |
| Source Control | CodeEditorSourceControl + Git CLI | SCM navigator + branch status |
| Output / Problems | CodeEditorTasks | Utility tabs; sample diagnostic task |
| Terminal | CodeEditorTerminal | Utility terminal (process-pipe shell) |
| Languages | CodeEditorLanguageSwift | Swift highlighting |

## Shortcuts

| Shortcut | Action |
|---|---|
| ⇧⌘O | Open Quickly |
| ⇧⌘P | Command Palette |
| ⌘0 | Toggle Navigator |
| ⌥⌘0 | Toggle Inspector |
| ⇧⌘Y | Toggle Utility |
| ⇧⌘F | Find Navigator |
| ⌘B | Run Sample Task |

## Notes

- Sample project is created under a temp directory with `git init` + one dirty file for SCM.
- Terminal is not a full PTY; simple stdin/stdout shell in the project root.
- LSP is not started in this sample (optional later).
