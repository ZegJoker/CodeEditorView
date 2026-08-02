# DAP fixtures

Committed fixture program for `scripts/check-real-dap.sh` (DAP-N10 / REL-N08).

- `smoke.c` — tiny C program with a deterministic local `x = 42` and a stable `breakpoint_here` marker **after** the assignment so `variables`/`evaluate` observe `x=42`.

## Lifecycle exercised by the gate

1. discover `lldb-dap` (or `lldb-vscode`)
2. compile fixture with `clang -g -O0` (required — no `/bin/echo` soft path)
3. `initialize` (must `success=true`)
4. `launch` with `stopOnEntry=true`
5. `setBreakpoints` on fixture source `breakpoint_here` line (must verify)
6. `configurationDone` → entry stop
7. `continue` → **breakpoint hit** (`reason=breakpoint`)
8. `stackTrace` / `scopes` / `variables` — **must** include `x=42`
9. `evaluate` expression `x` — **must** contain `42`
10. `disconnect` with `terminateDebuggee` + process cleanup (adapter SIGTERM)

When `REQUIRE_REAL_DAP=1`, missing adapter is a hard failure. When the adapter is present, incomplete lifecycle / `success=false` / missing `x=42` is always a hard failure (no soft green-wash).
