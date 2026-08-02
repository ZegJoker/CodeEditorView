# Phase 5 notes — Ghostty terminal migration

**Source of truth:** `~/Downloads/CodeEditorView_Deep_Audit_Xcode26_Ghostty.md` §20–21, Phase 5 gate  
**Branch:** `remediation/audit-2026-08`  
**Policy:** TDD; no silent byte drop; production path not custom VT.

> Prior content of this file described an older “view façade” phase; that work lives under Phase 3 notes.

## Goal

Production integrated terminal: Ghostty engine + safe PTY transport + workbench surface + DAP `runInTerminal`, without custom `VTParser`/`TerminalScreen` on the live workbench path.

## Deliverables

| Item | Status |
|---|---|
| `GHOSTTY.pin` + `scripts/check-ghostty-pin.sh` | Done |
| `CGhosttyShim` ABI + PTY spawn C helper (`ce_pty_*`) | Done |
| `TerminalByteTransport` / `MockByteTransport` / `LocalPTYTransport` | Done |
| Non-lossy ordered events; overflow fatal; EAGAIN wait (no busy-spin) | Done |
| `TerminalService` sessions, closeAll, config-only restore | Done |
| `GhosttySessionController` actor + requireLinked fail-closed | Done |
| `GhosttySurfaceView` / `GhosttySurfaceRepresentable` | Done |
| Workbench terminal panel uses Ghostty surface (not TerminalScreen dump) | Done |
| `GhosttyRunInTerminalHandler` → TerminalService | Done |
| `TerminalSecurityPolicy` OSC52 deny; shell integration trust-gated | Done |
| `GhosttyAccessibilityAdapter` | Done |
| Custom VT retained only for legacy `TerminalSessionManager` / unit tests | Documented |

## Gate evidence

```text
./scripts/check-ghostty-pin.sh
# OK: pin valid

swift test --filter 'Phase5|GhosttyShim|Terminal'
# 32 tests / 8 suites — all passed
```

### Key tests

| Exit | Test |
|---|---|
| E5 ordered / no drop | `mockTransportOrderedEchoNoDrop` |
| E5 overflow visible | `overflowTerminatesVisibly` |
| E9 service lifecycle | `terminalServiceCreateWriteClose`, `closeAllOnReplace` |
| E2 require linked | `requireGhosttyLinkedFailsClosed`, `requireLinkedThrowsWhenUnlinked` |
| E3 UTF-8 chunks | `utf8BoundaryChunksCoalesceInSnapshot` |
| E11 security | `securityPolicyOSC52DeniedByDefault` |
| E12 a11y | `accessibilityAdapterFromSnapshot` |
| E10 DAP | `runInTerminalCreatesDebuggeeSession` |
| E15 soak | `soakCreateCloseControllers` |

## Linked Ghostty

Default package evaluate builds **unlinked** (`ce_ghostty_is_linked() == false`) with shim spool for lifecycle tests. Production hosts:

```bash
./scripts/build-ghostty.sh vt
export CODEEDITOR_GHOSTTY_LINKED=1
# then swift build / app
```

When unlinked, `requireLinked: true` fails closed (no fake production terminal claim).

## Residual vs full §21.14 Stable

Automated suite covers architecture + lifecycle + policy. Full Stable still needs linked-lib soak (100 MiB, Kitty keyboard, VoiceOver manual) on CI with Ghostty build artifact — tracked as follow-on hardening, not a soft-stub of Phase 5 architecture.

## Defects

TER-001…TER-008 closed with evidence above.

## Related

- Phase 4 workspace trust gates process/PTY  
- Phase 6 LSP matrix (separate)
