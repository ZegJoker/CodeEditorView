#!/usr/bin/env bash
# Validate that the pinned Swift WASI SDK is available (or document install path).
# Set WASI_SDK_REQUIRED=1 to fail when missing (CI wasi-sdk job).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIN_FILE="Docs/Architecture/WASI-SDK.pin"
if [[ ! -f "$PIN_FILE" ]]; then
  echo "FAIL: missing $PIN_FILE" >&2
  exit 1
fi

PIN="$(grep -v '^#' "$PIN_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
if [[ -z "$PIN" ]]; then
  echo "FAIL: empty pin in $PIN_FILE" >&2
  exit 1
fi

echo "Pinned WASI SDK id: $PIN"

if [[ -n "${CODEEDITOR_WASI_SDK_ID:-}" ]]; then
  PIN="$CODEEDITOR_WASI_SDK_ID"
  echo "Override CODEEDITOR_WASI_SDK_ID=$PIN"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "FAIL: swift not on PATH" >&2
  exit 1
fi

LIST_OUT="$(swift sdk list 2>/dev/null || true)"
if echo "$LIST_OUT" | grep -Fqi "$PIN"; then
  echo "OK:   pinned WASI SDK present in 'swift sdk list'"
  exit 0
fi

echo "WARN: pinned WASI SDK not installed on this machine"
echo "      Install per Docs/Architecture/TOOLCHAIN.md then re-run."
echo "      Current 'swift sdk list':"
echo "${LIST_OUT:-"(empty)"}"

if [[ "${WASI_SDK_REQUIRED:-0}" == "1" ]]; then
  # Attempt documented install when URL provided
  if [[ -n "${CODEEDITOR_WASI_SDK_URL:-}" ]]; then
    echo "Attempting: swift sdk install $CODEEDITOR_WASI_SDK_URL"
    if swift sdk install "$CODEEDITOR_WASI_SDK_URL"; then
      LIST_OUT="$(swift sdk list 2>/dev/null || true)"
      if echo "$LIST_OUT" | grep -Fqi "$PIN"; then
        echo "OK:   installed and verified"
        exit 0
      fi
    fi
  fi
  echo "FAIL: WASI_SDK_REQUIRED=1 and pin not present"
  exit 1
fi

echo "OK:   pin file valid (install deferred on this host; CI may require install)"
exit 0
