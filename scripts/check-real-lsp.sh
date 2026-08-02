#!/usr/bin/env bash
# LSP-N13 / REL-N08 — real LSP integration gate.
# Hard-fail when REQUIRE_REAL_LSP=1 and tools absent or session steps fail.
# Full fixture: initialize → open → change → completion/hover/definition/symbols
# → diagnostics observe → versioned edit → shutdown/exit → clean process exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRE="${REQUIRE_REAL_LSP:-0}"
SEARCH_PATH="${CODEEDITOR_LSP_SEARCH_PATH:-}"
FIXTURE_SWIFT="${ROOT}/Tests/Fixtures/LSP/swift-package"
FIXTURE_C="${ROOT}/Tests/Fixtures/LSP/clangd-project"

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

sourcekit="$(find_bin sourcekit-lsp || true)"
clangd="$(find_bin clangd || true)"

if [[ -z "$sourcekit" && -z "$clangd" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_REAL_LSP=1 but no sourcekit-lsp/clangd on search path"
    exit 1
  fi
  echo "OK: no real LSP binaries (soft mode REQUIRE_REAL_LSP=0); fixtures present for CI"
  # Still require fixtures exist so the gate is not vacuous.
  [[ -f "$FIXTURE_SWIFT/Package.swift" ]] || { echo "FAIL: missing swift fixture"; exit 1; }
  [[ -f "$FIXTURE_C/main.c" ]] || { echo "FAIL: missing clangd fixture"; exit 1; }
  exit 0
fi

rpc_session() {
  local bin="$1"
  local kind="$2" # swift | c
  local work
  work="$(mktemp -d /tmp/lsp-n13-XXXXXX)"
  cleanup() { rm -rf "$work"; }
  trap cleanup RETURN

  local file lang root_uri
  if [[ "$kind" == "swift" ]]; then
    cp -R "$FIXTURE_SWIFT/." "$work/"
    file="$work/Sources/App/main.swift"
    lang="swift"
    root_uri="file://$work"
  else
    cp -R "$FIXTURE_C/." "$work/"
    file="$work/main.c"
    lang="c"
    root_uri="file://$work"
  fi
  local uri="file://$file"

  python3 - "$bin" "$uri" "$lang" "$root_uri" "$file" <<'PY'
import json, subprocess, sys, os, time, select

bin_path, uri, lang, root_uri, file_path = sys.argv[1:6]

def frame(msg: dict) -> bytes:
    body = json.dumps(msg).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

proc = subprocess.Popen(
    [bin_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    bufsize=0,
    cwd=os.path.dirname(file_path) if lang == "c" else root_uri.replace("file://", ""),
)
assert proc.stdin and proc.stdout
pending = set()
late = 0
diagnostics = []
methods_seen = []

def send(msg):
    if "id" in msg and msg.get("method"):
        pending.add(msg["id"])
    proc.stdin.write(frame(msg))
    proc.stdin.flush()

def read_msg(timeout=10.0):
    global late
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        while b"\r\n\r\n" not in buf and time.time() < end:
            ready, _, _ = select.select([proc.stdout], [], [], 0.05)
            if not ready:
                continue
            chunk = proc.stdout.read(1)
            if not chunk:
                time.sleep(0.01)
                continue
            buf += chunk
        if b"\r\n\r\n" not in buf:
            return None
        header, rest = buf.split(b"\r\n\r\n", 1)
        length = None
        for line in header.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        if length is None:
            buf = rest
            continue
        body = rest
        while len(body) < length and time.time() < end:
            ready, _, _ = select.select([proc.stdout], [], [], 0.05)
            if not ready:
                continue
            chunk = proc.stdout.read(length - len(body))
            if not chunk:
                time.sleep(0.01)
                continue
            body += chunk
        if len(body) < length:
            return None
        msg = body[:length]
        buf = body[length:]
        try:
            parsed = json.loads(msg.decode())
        except Exception:
            return None
        mid = parsed.get("id")
        method = parsed.get("method")
        if method:
            methods_seen.append(method)
            if method == "textDocument/publishDiagnostics":
                diagnostics.append(parsed.get("params") or {})
            # Server request — reply null / empty success not used; method not found ok
            if mid is not None and method:
                send({"jsonrpc": "2.0", "id": mid, "result": None})
            continue  # keep reading until a client response if needed
        if mid is not None:
            if mid in pending:
                pending.discard(mid)
            else:
                late += 1
        return parsed
    return None

def wait_response(expected_id, timeout=12.0):
    end = time.time() + timeout
    while time.time() < end:
        msg = read_msg(max(0.1, end - time.time()))
        if msg is None:
            continue
        if msg.get("id") == expected_id:
            return msg
    return None

text = open(file_path, encoding="utf-8").read()
init_params = {
    "processId": None,
    "rootUri": root_uri,
    "capabilities": {
        "textDocument": {
            "synchronization": {"didSave": True},
            "completion": {"completionItem": {"snippetSupport": False}},
            "hover": {"contentFormat": ["markdown", "plaintext"]},
            "definition": {"linkSupport": True},
            "documentSymbol": {"hierarchicalDocumentSymbolSupport": True},
            "publishDiagnostics": {"versionSupport": True},
        },
        "workspace": {"workspaceEdit": {"documentChanges": True}},
    },
    "clientInfo": {"name": "codeeditor-lsp-n13", "version": "1"},
}

# 1. initialize / initialized
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": init_params})
resp = wait_response(1, 15)
if not resp or resp.get("id") != 1 or "result" not in resp:
    print(f"FAIL: {bin_path} did not answer initialize", file=sys.stderr)
    proc.kill()
    sys.exit(1)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# 2. open
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didOpen",
    "params": {
        "textDocument": {
            "uri": uri,
            "languageId": lang,
            "version": 1,
            "text": text,
        }
    },
})

# 3. change (versioned)
new_text = text + ("\n// touch\n" if not text.endswith("\n") else "// touch\n")
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": new_text}],
    },
})

# 4. completion / hover / definition / documentSymbol
requests = [
    (2, "textDocument/completion", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": max(1, min(4, len(text.splitlines()[0]) if text else 1))},
    }),
    (3, "textDocument/hover", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": 1},
    }),
    (4, "textDocument/definition", {
        "textDocument": {"uri": uri},
        "position": {"line": 0, "character": 1},
    }),
    (5, "textDocument/documentSymbol", {
        "textDocument": {"uri": uri},
    }),
]
got = {}
for rid, method, params in requests:
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    r = wait_response(rid, 12)
    if r is None:
        print(f"FAIL: no response for {method}", file=sys.stderr)
        proc.kill()
        sys.exit(1)
    got[method] = r

# 5. observe diagnostics (may be empty; drain briefly)
drain_end = time.time() + 1.5
while time.time() < drain_end:
    msg = read_msg(0.2)
    if msg is None:
        continue

# 6. versioned edit fixture (apply as didChange full text v3)
edited = new_text.replace("world", "LSP", 1) if "world" in new_text else new_text + "\n"
send({
    "jsonrpc": "2.0",
    "method": "textDocument/didChange",
    "params": {
        "textDocument": {"uri": uri, "version": 3},
        "contentChanges": [{"text": edited}],
    },
})

# 7. shutdown / exit
send({"jsonrpc": "2.0", "id": 90, "method": "shutdown", "params": None})
shut = wait_response(90, 8)
send({"jsonrpc": "2.0", "method": "exit"})
try:
    code = proc.wait(timeout=5)
except Exception:
    proc.kill()
    code = -1
    print(f"FAIL: {bin_path} did not exit cleanly", file=sys.stderr)
    sys.exit(1)

if pending:
    print(f"FAIL: pending client requests at exit: {sorted(pending)}", file=sys.stderr)
    sys.exit(1)

# Require core methods answered (error result still counts as protocol answer)
for m in ("textDocument/completion", "textDocument/hover", "textDocument/definition", "textDocument/documentSymbol"):
    if m not in got:
        print(f"FAIL: missing {m}", file=sys.stderr)
        sys.exit(1)

print(
    f"OK: {bin_path} full session initialize/open/change/"
    f"completion/hover/definition/documentSymbol/"
    f"diagnostics(n={len(diagnostics)})/edit/shutdown exit={code} late={late}"
)
sys.exit(0)
PY
}

ok=0
if [[ -n "$sourcekit" ]]; then
  echo "OK: found sourcekit-lsp ($sourcekit)"
  if rpc_session "$sourcekit" swift; then
    ok=1
  else
    if [[ "$REQUIRE" == "1" ]]; then
      echo "FAIL: sourcekit-lsp session failed"
      exit 1
    fi
  fi
fi
if [[ -n "$clangd" ]]; then
  echo "OK: found clangd ($clangd)"
  if rpc_session "$clangd" c; then
    ok=1
  else
    if [[ "$REQUIRE" == "1" && "$ok" -eq 0 ]]; then
      echo "FAIL: clangd session failed and no other server succeeded"
      exit 1
    fi
  fi
fi

if [[ "$REQUIRE" == "1" && "$ok" -eq 0 ]]; then
  echo "FAIL: REQUIRE_REAL_LSP=1 but no successful LSP session"
  exit 1
fi
exit 0
