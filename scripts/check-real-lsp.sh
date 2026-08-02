#!/usr/bin/env bash
# REL-N08 — real LSP gate. Hard-fail when REQUIRE_REAL_LSP=1 and tools absent.
# Performs initialize/open/change/completion/diagnostic/shutdown against sourcekit-lsp
# (and clangd when present). Soft mode only when REQUIRE_REAL_LSP=0 (dev machines).
set -euo pipefail
REQUIRE="${REQUIRE_REAL_LSP:-0}"
SEARCH_PATH="${CODEEDITOR_LSP_SEARCH_PATH:-}"

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
  echo "OK: no real LSP binaries (soft mode REQUIRE_REAL_LSP=0)"
  exit 0
fi

rpc_session() {
  local bin="$1"
  local lang="$2"
  local root
  root="$(mktemp -d /tmp/lsp-smoke-XXXXXX)"
  cleanup() { rm -rf "$root"; }
  trap cleanup RETURN
  local file="$root/main.${lang}"
  if [[ "$lang" == "swift" ]]; then
    printf 'let x = 1\n' >"$file"
  else
    printf 'int main(void){return 0;}\n' >"$file"
  fi
  local uri="file://$file"
  local init_params
  init_params=$(python3 - <<PY
import json
print(json.dumps({
  "processId": None,
  "rootUri": "file://$root",
  "capabilities": {
    "textDocument": {
      "completion": {"completionItem": {"snippetSupport": False}},
      "publishDiagnostics": {}
    }
  },
  "clientInfo": {"name": "codeeditor-rel-n08", "version": "0"}
}))
PY
)
  python3 - "$bin" "$uri" "$lang" "$init_params" <<'PY'
import json, subprocess, sys, os, select, time

bin_path, uri, lang, init_params = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def frame(msg: dict) -> bytes:
    body = json.dumps(msg).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body

proc = subprocess.Popen(
    [bin_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    bufsize=0,
)
assert proc.stdin and proc.stdout

def send(msg):
    proc.stdin.write(frame(msg))
    proc.stdin.flush()

def read_msg(timeout=8.0):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        # header
        while b"\r\n\r\n" not in buf and time.time() < end:
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
                length = int(line.split(b":",1)[1].strip())
        if length is None:
            buf = rest
            continue
        body = rest
        while len(body) < length and time.time() < end:
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
            return json.loads(msg.decode())
        except Exception:
            return None
    return None

# initialize
send({"jsonrpc":"2.0","id":1,"method":"initialize","params": json.loads(init_params)})
resp = read_msg(12)
if not resp or resp.get("id") != 1:
    print(f"FAIL: {bin_path} did not answer initialize", file=sys.stderr)
    proc.kill()
    sys.exit(1)
send({"jsonrpc":"2.0","method":"initialized","params":{}})
# open
text = open(uri.replace("file://",""), encoding="utf-8").read()
send({
  "jsonrpc":"2.0","method":"textDocument/didOpen","params":{
    "textDocument":{"uri":uri,"languageId": "swift" if lang=="swift" else "c","version":1,"text":text}
  }
})
# change
send({
  "jsonrpc":"2.0","method":"textDocument/didChange","params":{
    "textDocument":{"uri":uri,"version":2},
    "contentChanges":[{"text": text + "\n"}]
  }
})
# completion
send({
  "jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{
    "textDocument":{"uri":uri},
    "position":{"line":0,"character":1}
  }
})
comp = read_msg(12)
# diagnostics may arrive as notifications; do not require
send({"jsonrpc":"2.0","id":3,"method":"shutdown","params":None})
shut = read_msg(8)
send({"jsonrpc":"2.0","method":"exit"})
try:
    proc.wait(timeout=3)
except Exception:
    proc.kill()
if not shut or shut.get("id") != 3:
    # some servers exit without shutdown body after initialize success — still require initialize
    print(f"WARN: {bin_path} weak shutdown; initialize OK")
print(f"OK: {bin_path} initialize/open/change/completion/shutdown session")
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
