#!/usr/bin/env bash
# DAP-N10 / REL-N08 — real DAP adapter gate. Hard-fail when REQUIRE_REAL_DAP=1.
# Exercises complete lifecycle against lldb-dap with Tests/Fixtures/DAP/smoke.c:
# initialize / launch(stopOnEntry) / setBreakpoints / configurationDone /
# continue → breakpoint hit / stackTrace / scopes / variables / evaluate /
# disconnect + process cleanup.
#
# Acceptance (hard when adapter present):
#   - stackTrace / evaluate must success=true (not mere response presence)
#   - fixture breakpoint must be hit (reason=breakpoint)
#   - locals must show x=42 (and evaluate of x contains 42)
# Silent no-op or success=false on those steps is a hard failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRE="${REQUIRE_REAL_DAP:-0}"
SEARCH_PATH="${CODEEDITOR_DAP_SEARCH_PATH:-}"
OVERALL_TIMEOUT="${CODEEDITOR_DAP_TIMEOUT_SEC:-30}"
FIXTURE_DIR="${CODEEDITOR_DAP_FIXTURE_DIR:-$ROOT/Tests/Fixtures/DAP}"
FIXTURE_SRC="$FIXTURE_DIR/smoke.c"

if [[ ! -f "$FIXTURE_SRC" ]]; then
  echo "FAIL: DAP fixture missing at $FIXTURE_SRC"
  exit 1
fi
echo "OK: fixtures present ($FIXTURE_SRC)"

find_bin() {
  local name="$1"
  if [[ -n "$SEARCH_PATH" ]]; then
    if [[ -x "$SEARCH_PATH/$name" ]]; then
      echo "$SEARCH_PATH/$name"
      return 0
    fi
    return 1
  fi
  command -v "$name" 2>/dev/null || true
}

found=""
for bin in lldb-dap lldb-vscode; do
  p="$(find_bin "$bin" || true)"
  if [[ -n "$p" ]]; then
    found="$p"
    break
  fi
done

if [[ -z "$found" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_REAL_DAP=1 but no lldb-dap/lldb-vscode on search path"
    exit 1
  fi
  echo "OK: no real DAP adapter / no lldb-dap (soft mode REQUIRE_REAL_DAP=0); fixtures present"
  exit 0
fi

echo "OK: found $found"

export CODEEDITOR_DAP_TIMEOUT_SEC="$OVERALL_TIMEOUT"
python3 - "$found" "$REQUIRE" "$FIXTURE_SRC" <<'PY'
import json, subprocess, sys, time, select, os, signal, tempfile, shutil, re

adapter = sys.argv[1]
require = sys.argv[2] == "1"
fixture_src = sys.argv[3]
deadline = time.time() + float(os.environ.get("CODEEDITOR_DAP_TIMEOUT_SEC", "30"))

def fail(msg):
    print("FAIL: %s" % msg, file=sys.stderr)
    raise SystemExit(1)

def frame(obj: dict) -> bytes:
    body = json.dumps(obj).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

# Compile committed fixture into a temp dir (do not mutate repo).
dbg_dir = tempfile.mkdtemp(prefix="codeeditor-dap-")
dbg_src = os.path.join(dbg_dir, "smoke.c")
dbg_bin = os.path.join(dbg_dir, "smoke")
shutil.copy2(fixture_src, dbg_src)

try:
    c = subprocess.run(
        ["clang", "-g", "-O0", "-o", dbg_bin, dbg_src],
        capture_output=True,
        timeout=15,
    )
    compiled = c.returncode == 0 and os.path.isfile(dbg_bin)
except Exception as e:
    compiled = False
    c = type("R", (), {"stderr": str(e).encode(), "returncode": -1})()

if not compiled:
    # Real gate requires the fixture binary — never soft-pass with /bin/echo.
    fail(
        "could not compile Tests/Fixtures/DAP/smoke.c with clang (required for x=42 lifecycle): %s"
        % (getattr(c, "stderr", b"")[:400].decode(errors="replace") if hasattr(c, "stderr") else "")
    )

program = dbg_bin
bp_source = dbg_src
bp_line = None
try:
    with open(dbg_src, "r", encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            # Prefer executable line: marker must appear on a non-comment-only line.
            stripped = line.strip()
            if "breakpoint_here" not in line:
                continue
            if stripped.startswith("/*") or stripped.startswith("*") or stripped.startswith("//"):
                continue
            bp_line = i
            break
except Exception:
    pass
if bp_line is None:
    fail("fixture smoke.c missing executable breakpoint_here marker")

proc = subprocess.Popen(
    [adapter],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    bufsize=0,
)
assert proc.stdin and proc.stdout
buf = b""
seq = 1
responses = {}
events = []

def remaining():
    return max(0.05, deadline - time.time())

def send(obj):
    try:
        proc.stdin.write(frame(obj))
        proc.stdin.flush()
    except BrokenPipeError:
        pass

def read_msg(timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end and time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], min(0.2, end - time.time()))
        if ready:
            chunk = proc.stdout.read(8192)
            if not chunk:
                time.sleep(0.01)
            else:
                buf += chunk
        if b"\r\n\r\n" not in buf:
            if proc.poll() is not None and not ready:
                return None
            continue
        header, rest = buf.split(b"\r\n\r\n", 1)
        length = None
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        if length is None:
            buf = rest
            continue
        body = rest
        while len(body) < length and time.time() < end and time.time() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not ready:
                continue
            chunk = proc.stdout.read(length - len(body))
            if not chunk:
                continue
            body += chunk
        if len(body) < length:
            return None
        raw = body[:length]
        buf = body[length:]
        try:
            return json.loads(raw.decode())
        except Exception:
            continue
    return None

def req_send(command, arguments=None):
    global seq
    msg = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        msg["arguments"] = arguments
    seq += 1
    send(msg)
    return command

def pump(wait=3.0, want_cmd=None, want_event=None):
    """Drain until deadline; capture responses/events. Optionally return matching msg.

    Does not extend the wait on unrelated module/output floods (overall budget is fixed).
    """
    end = time.time() + min(wait, remaining())
    found = None
    while time.time() < end and time.time() < deadline:
        m = read_msg(min(0.4, end - time.time()))
        if not m:
            continue
        if m.get("type") == "response":
            cmd = m.get("command")
            if cmd:
                responses[cmd] = m
            if want_cmd and cmd == want_cmd:
                found = m
                # Brief tail drain only — do not reopen long waits.
                end = min(end, time.time() + 0.15)
        elif m.get("type") == "event":
            events.append(m)
            if want_event and m.get("event") == want_event:
                found = m
                end = min(end, time.time() + 0.15)
    return found

def require_success(command):
    """Hard-require a success=true DAP response (DAP-N10)."""
    if command not in responses:
        fail("%s produced no response (silent no-op forbidden)" % command)
    m = responses[command]
    if m.get("success") is not True:
        fail(
            "%s success is not True (got success=%s message=%s body=%s)"
            % (command, m.get("success"), m.get("message"), m.get("body"))
        )
    print("OK: %s success=True" % command)
    return m

try:
    req_send("initialize", {
        "clientID": "codeeditor-dap-n10",
        "adapterID": "lldb",
        "pathFormat": "path",
        "linesStartAt1": True,
        "columnsStartAt1": True,
        "supportsVariableType": True,
        "supportsRunInTerminalRequest": True,
    })
    init = pump(wait=6.0, want_cmd="initialize")
    if not init or init.get("success") is not True:
        fail("initialize must succeed: %s" % init)
    print("OK: initialize success=True")
    # Best-effort drain of initialized event (may arrive interleaved).
    pump(wait=1.0, want_event="initialized")

    # stopOnEntry so we can set breakpoints before the process runs away.
    req_send("launch", {
        "program": program,
        "args": [],
        "name": "smoke",
        "cwd": dbg_dir,
        "stopOnEntry": True,
    })
    req_send("setBreakpoints", {
        "source": {"path": bp_source},
        "breakpoints": [{"line": bp_line}],
    })
    pump(wait=3.0, want_cmd="setBreakpoints")
    sb = require_success("setBreakpoints")
    bps = (sb.get("body") or {}).get("breakpoints") or []
    if not bps or not bps[0].get("verified"):
        fail("fixture breakpoint not verified: %s" % bps)

    req_send("configurationDone", {})
    # Wait for entry stop; lldb-dap often sends stopped BEFORE launch response.
    stopped = None
    end = time.time() + min(12.0, remaining())
    while time.time() < end:
        m = read_msg(min(0.5, end - time.time()))
        if not m:
            # If we already have stop + launch, done.
            if stopped is not None and "launch" in responses:
                break
            continue
        if m.get("type") == "response":
            cmd = m.get("command")
            if cmd:
                responses[cmd] = m
        elif m.get("type") == "event":
            events.append(m)
            if m.get("event") == "stopped" and stopped is None:
                stopped = m
        if stopped is not None and "launch" in responses and "configurationDone" in responses:
            break
    if stopped is None:
        fail("no stopped event after launch/configurationDone (stopOnEntry)")
    require_success("launch")
    if "configurationDone" in responses:
        require_success("configurationDone")
    entry_reason = (stopped.get("body") or {}).get("reason")
    thread_id = (stopped.get("body") or {}).get("threadId") or 1
    print("OK: entry stop reason=%s threadId=%s" % (entry_reason, thread_id))

    # Continue to the fixture source breakpoint (module floods are expected; keep a firm window).
    req_send("continue", {"threadId": thread_id})
    cont = pump(wait=3.0, want_cmd="continue")
    if cont is not None or "continue" in responses:
        require_success("continue")

    bp_stopped = None
    # Fixed window independent of prior burns (still capped by overall deadline).
    bp_window = min(15.0, max(5.0, remaining()))
    end = time.time() + bp_window
    while time.time() < end and bp_stopped is None and time.time() < deadline:
        m = read_msg(min(0.5, end - time.time()))
        if not m:
            continue
        if m.get("type") == "response":
            cmd = m.get("command")
            if cmd:
                responses[cmd] = m
        elif m.get("type") == "event":
            events.append(m)
            if m.get("event") == "stopped":
                reason = (m.get("body") or {}).get("reason")
                if reason == "breakpoint" or (m.get("body") or {}).get("hitBreakpointIds"):
                    bp_stopped = m
            if m.get("event") in ("exited", "terminated"):
                fail("process exited/terminated before fixture breakpoint hit")
    if bp_stopped is None:
        fail(
            "fixture breakpoint not hit (no stopped reason=breakpoint); remaining=%.2fs events=%d"
            % (remaining(), len(events))
        )
    body = bp_stopped.get("body") or {}
    thread_id = body.get("threadId") or thread_id
    print(
        "OK: breakpoint hit reason=%s hitBreakpointIds=%s"
        % (body.get("reason"), body.get("hitBreakpointIds"))
    )

    req_send("stackTrace", {"threadId": thread_id})
    pump(wait=4.0, want_cmd="stackTrace")
    st = require_success("stackTrace")
    frames = (st.get("body") or {}).get("stackFrames") or []
    if not frames:
        fail("stackTrace returned no frames")
    frame0 = frames[0]
    frame_id = frame0.get("id")
    if frame_id is None:
        fail("stack frame missing id: %s" % frame0)
    print("OK: stackTrace frame name=%s line=%s" % (frame0.get("name"), frame0.get("line")))

    req_send("scopes", {"frameId": frame_id})
    pump(wait=3.0, want_cmd="scopes")
    scopes_msg = require_success("scopes")
    scopes = (scopes_msg.get("body") or {}).get("scopes") or []
    if not scopes:
        fail("scopes empty")
    var_ref = scopes[0].get("variablesReference")
    if var_ref is None:
        fail("scope missing variablesReference")

    req_send("variables", {"variablesReference": var_ref})
    pump(wait=3.0, want_cmd="variables")
    vars_msg = require_success("variables")
    variables = (vars_msg.get("body") or {}).get("variables") or []
    x_var = None
    for v in variables:
        if v.get("name") == "x":
            x_var = v
            break
    if x_var is None:
        fail("locals missing variable x: %s" % variables)
    x_val = str(x_var.get("value", "")).strip()
    # Accept "42" or typed forms; reject garbage / uninitialized.
    if x_val != "42" and not re.search(r"(^|[^0-9-])42([^0-9]|$)", x_val):
        fail("expected variable x=42, got value=%r" % x_val)
    print("OK: variable x=42 (value=%r)" % x_val)

    req_send("evaluate", {
        "expression": "x",
        "frameId": frame_id,
        "context": "repl",
    })
    pump(wait=3.0, want_cmd="evaluate")
    ev = require_success("evaluate")
    ev_body = ev.get("body") or {}
    ev_result = str(ev_body.get("result") or ev_body.get("value") or "")
    if "42" not in ev_result:
        fail("evaluate x must contain 42, got %r" % ev_result)
    print("OK: evaluate x contains 42 (result=%r)" % ev_result)

    req_send("disconnect", {"terminateDebuggee": True})
    pump(wait=3.0, want_cmd="disconnect")
    require_success("disconnect")

    print(
        "OK: full session / complete lifecycle "
        "initialize/launch/breakpoint hit/stackTrace/variables x=42/evaluate/disconnect"
    )
    raise SystemExit(0)
finally:
    # Process cleanup: ensure adapter (and debuggee) are not left running.
    try:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()
                try:
                    proc.wait(timeout=1)
                except Exception:
                    pass
        print("OK: process cleanup (adapter SIGTERM/kill)")
    except Exception as e:
        print("WARN: process cleanup: %s" % e)
    try:
        shutil.rmtree(dbg_dir, ignore_errors=True)
    except Exception:
        pass
PY
status=$?

if [[ "$status" -ne 0 ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: real DAP session failed (exit $status)"
    exit 1
  fi
  # Soft mode: still exit non-zero when adapter was found but lifecycle failed —
  # only missing-adapter soft-exits 0 above. Incomplete session must not green-wash.
  echo "FAIL: real DAP session incomplete (adapter present; soft mode still reports failure for tests)"
  exit 1
fi
exit 0
