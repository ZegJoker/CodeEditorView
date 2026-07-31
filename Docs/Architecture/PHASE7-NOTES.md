# Phase 7 notes — Tasks, Terminal, and Source Control

## Goal

Cancellable process trees with live output; real PTY + VT screen model; filename-safe Git with explicit mutations and integrity under failure.

## Ownership

```
ProcessService (Core)
  ├─ ProcessTaskRunner / TaskService / problem matchers
  ├─ GitCLIProvider (streaming git CLI)
  └─ (pipes shared pattern)

Terminal
  ├─ VTParser + TerminalScreen (core emulator)
  ├─ PTYTerminalBackend (macOS, localPTY)
  ├─ ProcessTerminalBackend (legacy pipe, localProcess)
  └─ RemoteTerminalBackend + RemoteTerminalTransport (iOS/host path)
```

## Tasks deliverables

| Item | Status |
|---|---|
| `ProcessService` process groups, stream, timeout, cancel | Done |
| `TaskExecutionHandle` live stdout/stderr + cancel | Done |
| Shell vs direct + `ShellQuoting` | Done |
| Variables, presentation, exclusive concurrency, background readiness | Done |
| Streaming + multiline-capable problem matchers + path security | Done |
| `HostTaskRunner` / `FakeTaskRunner` for non-process profiles | Done |

## Terminal deliverables

| Item | Status |
|---|---|
| VT parser (CSI/OSC/C0) + bounded screen/scrollback | Done |
| SGR, alt screen, cursor, erase, bracketed paste flag | Done |
| Unicode width (CJK/emoji/combining) | Done |
| Selection, URL detect, a11y text, paste encoding | Done |
| macOS `forkpty` backend + resize ioctl + group kill | Done |
| Remote transport contract + mock disconnect | Done |
| iOS/localPTY fail-closed | Done |

## SourceControl deliverables

| Item | Status |
|---|---|
| `git status -z` NUL parser | Done |
| Discovery walk-up for `.git` | Done |
| Path validation / escape rejection | Done |
| Full provider surface (no silent no-ops) | Done |
| Stage/unstage/discard/commit/branch/log/blame/diff/hunks/remotes/fetch/pull/push | Done |
| Trust gate + cancel active git process | Done |
| Unavailable provider for non-CLI platforms | Done |

## Gate evidence

| Check | Result |
|---|---|
| `swift test --filter 'CodeEditorTasks\|CodeEditorTerminal\|CodeEditorSourceControl'` | **44 tests / 4 suites — passed** |
| Task cancel kills sleep process | Pass |
| Task timeout | Pass |
| PTY interactive (macOS) | Pass |
| VT corpus + adversarial CSI | Pass |
| Git fixture with spaces in path + stage/commit | Pass |
| Path escape / profile fail-closed | Pass |

## Residual

- Nightly required sourcekit/git remote servers beyond local fixtures  
- Full Unicode East Asian Width table (subset implemented)  
- libgit2 provider implementation (protocol ready; CLI is macOS path)  
- Terminal mouse modes full VT parity  

## Related

- Phase 6 LanguageServices/LSP  
- Phase 8 Workbench integration of tooling surfaces  
