#!/usr/bin/env bash
# REL-N08 — real DAP adapter gate. Hard-fail when REQUIRE_REAL_DAP=1.
# Exercises initialize / launch / setBreakpoints / stackTrace / variables / evaluate / disconnect
# against lldb-dap when available. Each post-initialize command must receive a response
# (success or structured failure) — silent no-op is a hard failure.
set -euo pipefail
REQUIRE="${REQUIRE_REAL_DAP:-0}"
SEARCH_PATH="${CODEEDITOR_DAP_SEARCH_PATH:-}"
OVERALL_TIMEOUT="${CODEEDITOR_DAP_TIMEOUT_SEC:-25}"

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
  echo "OK: no real DAP adapter (soft mode REQUIRE_REAL_DAP=0)"
  exit 0
fi

echo "OK: found $found"

python3 - "$found" "$REQUIRE" <<'PY'
import json, subprocess, sys, time, select, os, signal, tempfile, textwrap

adapter = sys.argv[1]
require = sys.argv[2] == "1"
deadline = time.time() + float(os.environ.get("CODEEDITOR_DAP_TIMEOUT_SEC", "20"))

def frame(obj: dict) -> bytes:
    body = json.dumps(obj).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

# Tiny debuggee for launch/breakpoint surface
dbg_dir = tempfile.mkdtemp(prefix="codeeditor-dap-")
dbg_src = os.path.join(dbg_dir, "smoke.c")
dbg_bin = os.path.join(dbg_dir, "smoke")
with open(dbg_src, "w", encoding="utf-8") as f:
    f.write(textwrap.dedent("""\
        #include <stdio.h>
        int main(void) {
            int x = 1;
            printf("codeeditor-dap-smoke %d\\n", x);
            return 0;
        }
    """))
# Best-effort compile; fall back to /bin/echo if clang missing
compiled = False
try:
    c = subprocess.run(["clang", "-g", "-O0", "-o", dbg_bin, dbg_src], capture_output=True, timeout=15)
    compiled = c.returncode == 0 and os.path.isfile(dbg_bin)
except Exception:
    compiled = False
program = dbg_bin if compiled else "/bin/echo"
program_args = [] if compiled else ["codeeditor-dap-smoke"]
bp_source = dbg_src if compiled else program

proc = subprocess.Popen(
    [adapter],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    bufsize=0,
)
assert proc.stdin and proc.stdout
buf = b""
got_initialize = False
responses = {}

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
            chunk = proc.stdout.read(1)
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

seq = 1
pending = set()

def req_send(command, arguments=None):
    global seq
    msg = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        msg["arguments"] = arguments
    seq += 1
    send(msg)
    pending.add(command)
    return command

def pump(wait=3.0, want=None):
    """Drain messages; capture responses. want=command to return when that response arrives."""
    global got_initialize
    end = time.time() + min(wait, remaining())
    found = None
    while time.time() < end and time.time() < deadline:
        m = read_msg(min(0.5, end - time.time()))
        if not m:
            continue
        if m.get("type") == "response":
            cmd = m.get("command")
            if cmd:
                responses[cmd] = m
                pending.discard(cmd)
                if cmd == "initialize":
                    got_initialize = True
                if want and cmd == want:
                    found = m
                    # keep brief drain for trailing events
                    end = min(end, time.time() + 0.3)
        # events extend slightly so we catch late responses (lldb-dap launch after configurationDone)
        elif m.get("type") == "event" and want:
            end = min(end + 0.2, time.time() + max(0.5, remaining()))
    return found if want else True

def require_response(command, soft_ok=False):
    if command not in responses:
        print("FAIL: %s produced no response (silent no-op forbidden)" % command, file=sys.stderr)
        raise SystemExit(1 if require else 0)
    m = responses[command]
    print("OK: %s response success=%s" % (command, m.get("success")))
    return m

required_commands = [
    "initialize",
    "launch",
    "setBreakpoints",
    "stackTrace",
    "variables",
    "evaluate",
    "disconnect",
]

try:
    req_send("initialize", {
        "clientID": "codeeditor-rel-n08",
        "adapterID": "lldb",
        "pathFormat": "path",
        "linesStartAt1": True,
        "columnsStartAt1": True,
        "supportsVariableType": True,
        "supportsRunInTerminalRequest": True,
    })
    init = pump(wait=6.0, want="initialize")
    if not init:
        print("FAIL: initialize produced no response within timeout", file=sys.stderr)
        raise SystemExit(1 if require else 0)
    if init.get("success") is False:
        print("FAIL: initialize success=false", init, file=sys.stderr)
        raise SystemExit(1 if require else 0)
    print("OK: initialize")

    # lldb-dap: launch may complete only after configurationDone
    req_send("launch", {
        "program": program,
        "args": program_args,
        "name": "smoke",
        "cwd": dbg_dir,
        "stopOnEntry": True if compiled else False,
    })
    pump(wait=1.5)  # drain initialized/process events
    req_send("configurationDone", {})
    pump(wait=4.0, want="launch")
    pump(wait=2.0, want="configurationDone")
    require_response("launch")

    req_send("setBreakpoints", {
        "source": {"path": bp_source},
        "breakpoints": [{"line": 3 if compiled else 1}],
    })
    pump(wait=3.0, want="setBreakpoints")
    require_response("setBreakpoints")

    # stack/vars/eval must answer (success may be false if not stopped)
    req_send("stackTrace", {"threadId": 1})
    pump(wait=3.0, want="stackTrace")
    st = require_response("stackTrace")

    var_ref = 1
    if st.get("success") and isinstance(st.get("body"), dict):
        frames = st["body"].get("stackFrames") or []
        if frames and isinstance(frames[0], dict):
            req_send("scopes", {"frameId": frames[0].get("id", 0)})
            pump(wait=2.0, want="scopes")
            scopes = responses.get("scopes")
            if scopes and scopes.get("success") and isinstance(scopes.get("body"), dict):
                sc = scopes["body"].get("scopes") or []
                if sc and isinstance(sc[0], dict):
                    var_ref = sc[0].get("variablesReference") or 1

    req_send("variables", {"variablesReference": var_ref})
    pump(wait=3.0, want="variables")
    require_response("variables")

    req_send("evaluate", {"expression": "1+1", "context": "repl"})
    pump(wait=3.0, want="evaluate")
    require_response("evaluate")

    req_send("disconnect", {"terminateDebuggee": True})
    pump(wait=3.0, want="disconnect")
    require_response("disconnect")

    missing = [c for c in required_commands if c not in responses]
    if missing:
        print("FAIL: missing DAP responses for: %s" % ", ".join(missing), file=sys.stderr)
        raise SystemExit(1 if require else 0)

    print("OK: lldb-dap initialize/launch/breakpoint/stack/variables/evaluate/disconnect all answered")
    raise SystemExit(0)
finally:
    try:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()
    except Exception:
        pass
    try:
        import shutil
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
  echo "WARN: real DAP session incomplete (soft mode)"
  exit 0
fi
exit 0
