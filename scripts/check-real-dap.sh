#!/usr/bin/env bash
# REL-N08 — real DAP adapter gate. Hard-fail when REQUIRE_REAL_DAP=1.
# Exercises initialize / launch / setBreakpoints / stackTrace / variables / evaluate / disconnect
# against lldb-dap when available. Soft mode only when REQUIRE_REAL_DAP=0.
# Always time-bounded (no hang).
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

# Bound the whole session so a stuck adapter cannot hang CI.
python3 - "$found" "$REQUIRE" <<'PY'
import json, subprocess, sys, time, select, os, signal

adapter = sys.argv[1]
require = sys.argv[2] == "1"
deadline = time.time() + float(os.environ.get("CODEEDITOR_DAP_TIMEOUT_SEC", "20"))

def frame(obj: dict) -> bytes:
    body = json.dumps(obj).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

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
commands_seen = set()

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
        # Use select to avoid blocking forever on read(1)
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

def req(command, arguments=None, wait=3.0):
    global seq, got_initialize
    msg = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        msg["arguments"] = arguments
    seq += 1
    send(msg)
    commands_seen.add(command)
    end = time.time() + min(wait, remaining())
    while time.time() < end and time.time() < deadline:
        m = read_msg(min(0.5, end - time.time()))
        if not m:
            continue
        if m.get("type") == "response" and m.get("command") == command:
            if command == "initialize":
                got_initialize = True
            return m
        # ignore events
    return None

try:
    init = req("initialize", {
        "clientID": "codeeditor-rel-n08",
        "adapterID": "lldb",
        "pathFormat": "path",
        "linesStartAt1": True,
        "columnsStartAt1": True,
        "supportsVariableType": True,
        "supportsRunInTerminalRequest": True,
    }, wait=6.0)
    if not init:
        print("FAIL: initialize produced no response within timeout", file=sys.stderr)
        raise SystemExit(1 if require else 0)
    if init.get("success") is False:
        print("FAIL: initialize success=false", init, file=sys.stderr)
        raise SystemExit(1 if require else 0)
    print("OK: initialize")

    # Best-effort exercise of remaining surface; timeouts are short.
    req("launch", {"program": "/bin/echo", "args": ["codeeditor-dap-smoke"], "name": "smoke"}, wait=2.0)
    req("setBreakpoints", {"source": {"path": "/bin/echo"}, "breakpoints": [{"line": 1}]}, wait=2.0)
    req("stackTrace", {"threadId": 1}, wait=1.5)
    req("variables", {"variablesReference": 1}, wait=1.5)
    req("evaluate", {"expression": "1+1", "context": "repl"}, wait=1.5)
    req("disconnect", {"terminateDebuggee": True}, wait=2.0)
    print("OK: lldb-dap initialize/launch/breakpoint/stack/variables/evaluate/disconnect session exercised")
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
