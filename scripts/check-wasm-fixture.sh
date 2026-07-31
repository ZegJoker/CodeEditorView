#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FIX="Tests/Fixtures/Wasm/conformance.wasm"
if [[ ! -f "$FIX" ]]; then
  echo "FAIL: missing $FIX"
  exit 1
fi
echo "OK:   conformance fixture present ($(wc -c < "$FIX") bytes)"
# Optional rebuild comparison
if [[ "${WASM_FIXTURE_REQUIRED:-0}" == "1" ]]; then
  ./scripts/build-wasm-extension.sh || exit 1
fi
exit 0
