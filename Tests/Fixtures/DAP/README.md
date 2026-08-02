# DAP fixtures

Committed fixture program for `scripts/check-real-dap.sh` (DAP-N10 / REL-N08).

- `smoke.c` — tiny C program with a deterministic local `x = 42` and a stable breakpoint line.

## Lifecycle exercised by the gate

1. discover `lldb-dap`
2. compile fixture (or use prebuilt if present)
3. initialize / launch / configurationDone
4. setBreakpoints on the fixture source
5. stackTrace / scopes / variables / evaluate
6. disconnect with terminateDebuggee
7. assert process cleanup (adapter SIGTERM)

When `REQUIRE_REAL_DAP=1`, missing adapter or incomplete session is a hard failure.
