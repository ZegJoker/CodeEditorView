#!/usr/bin/env bash
# Hard-gate: pinned Swift WASI SDK must be installed (install when URL is known).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIN_FILE="Docs/Architecture/WASI-SDK.pin"
if [[ ! -f "$PIN_FILE" ]]; then
  echo "FAIL: missing $PIN_FILE" >&2
  exit 1
fi

# Parse pin id + optional install URL/checksum from pin file
PIN="$(grep -v '^#' "$PIN_FILE" | grep -v '^[[:space:]]*$' | grep -v '=' | head -1 | tr -d '[:space:]')"
URL_LINE="$(grep -E '^INSTALL_URL=' "$PIN_FILE" || true)"
CHECKSUM_LINE="$(grep -E '^INSTALL_CHECKSUM=' "$PIN_FILE" || true)"
INSTALL_URL="${CODEEDITOR_WASI_SDK_URL:-}"
INSTALL_CHECKSUM="${CODEEDITOR_WASI_SDK_CHECKSUM:-}"
if [[ -n "$URL_LINE" && -z "$INSTALL_URL" ]]; then
  INSTALL_URL="${URL_LINE#INSTALL_URL=}"
fi
if [[ -n "$CHECKSUM_LINE" && -z "$INSTALL_CHECKSUM" ]]; then
  INSTALL_CHECKSUM="${CHECKSUM_LINE#INSTALL_CHECKSUM=}"
fi

if [[ -n "${CODEEDITOR_WASI_SDK_ID:-}" ]]; then
  PIN="$CODEEDITOR_WASI_SDK_ID"
fi

if [[ -z "$PIN" ]]; then
  echo "FAIL: empty pin in $PIN_FILE" >&2
  exit 1
fi

echo "Pinned WASI SDK id: $PIN"

if ! command -v swift >/dev/null 2>&1; then
  echo "FAIL: swift not on PATH" >&2
  exit 1
fi

list_sdks() {
  swift sdk list 2>/dev/null || true
}

if echo "$(list_sdks)" | grep -Fqi "$PIN"; then
  echo "OK:   pinned WASI SDK present in 'swift sdk list'"
  exit 0
fi

echo "Pinned WASI SDK not installed; attempting install…"
if [[ -z "$INSTALL_URL" ]]; then
  echo "FAIL: no INSTALL_URL in $PIN_FILE and CODEEDITOR_WASI_SDK_URL unset" >&2
  echo "      Current 'swift sdk list':" >&2
  list_sdks >&2 || true
  exit 1
fi

INSTALL_ARGS=("$INSTALL_URL")
if [[ -n "$INSTALL_CHECKSUM" ]]; then
  INSTALL_ARGS+=(--checksum "$INSTALL_CHECKSUM")
fi

echo "Running: swift sdk install ${INSTALL_ARGS[*]}"
if ! swift sdk install "${INSTALL_ARGS[@]}"; then
  echo "FAIL: swift sdk install failed" >&2
  exit 1
fi

if echo "$(list_sdks)" | grep -Fqi "$PIN"; then
  echo "OK:   installed and verified pinned WASI SDK"
  exit 0
fi

echo "FAIL: after install, pin '$PIN' still not in 'swift sdk list'" >&2
list_sdks >&2 || true
exit 1
