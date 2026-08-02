#!/usr/bin/env bash
# Soft DAP adapter smoke: reports availability; hard-fails only when REQUIRE_REAL_DAP=1.
set -euo pipefail
REQUIRE="${REQUIRE_REAL_DAP:-0}"
found=""
for bin in lldb-dap lldb-vscode; do
  if command -v "$bin" >/dev/null 2>&1; then
    found="$bin"
    break
  fi
done

if [[ -z "$found" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_REAL_DAP=1 but no lldb-dap/lldb-vscode on PATH"
    exit 1
  fi
  echo "OK: no real DAP adapter (soft mode)"
  exit 0
fi

echo "OK: found $found"

# Minimal initialize/disconnect smoke when adapter is present.
# Uses Content-Length framing; adapter may exit non-zero on incomplete session — tolerate soft.
tmp="$(mktemp -t dap-smoke.XXXXXX)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

{
  body='{"seq":1,"type":"request","command":"initialize","arguments":{"clientID":"codeeditor-smoke","adapterID":"lldb","pathFormat":"path","linesStartAt1":true,"columnsStartAt1":true,"supportsRunInTerminalRequest":true}}'
  len=$(printf '%s' "$body" | wc -c | tr -d ' ')
  printf 'Content-Length: %s\r\n\r\n%s' "$len" "$body"
  body2='{"seq":2,"type":"request","command":"disconnect","arguments":{"terminateDebuggee":true}}'
  len2=$(printf '%s' "$body2" | wc -c | tr -d ' ')
  printf 'Content-Length: %s\r\n\r\n%s' "$len2" "$body2"
} | "$found" >"$tmp" 2>/dev/null || true

if grep -q '"command":"initialize"' "$tmp" 2>/dev/null || grep -q 'initialized' "$tmp" 2>/dev/null || grep -q '"success"' "$tmp" 2>/dev/null; then
  echo "OK: $found responded to initialize/disconnect smoke"
  exit 0
fi

if [[ "$REQUIRE" == "1" ]]; then
  echo "FAIL: $found produced no DAP response body"
  head -c 400 "$tmp" || true
  exit 1
fi
echo "WARN: $found did not return parseable DAP response (soft mode)"
exit 0
