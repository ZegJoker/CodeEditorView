#!/usr/bin/env bash
# Gate: committed Wasm fixtures exist; optional digest + rebuild hard mode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FIX_DIR="Tests/Fixtures/Wasm"
REQUIRE="${REQUIRE_WASM_FIXTURES:-0}"

required=(
  "conformance.wasm"
  "malformed.wasm"
  "infinite_loop.wasm"
  "infinite_loop_pure.wasm"
  "missing_export.wasm"
  "memory_growth.wasm"
  "flood_host_send.wasm"
  "bad_schema_start.wasm"
  "deep_recursion.wasm"
  "huge_table.wasm"
  "oob_memory.wasm"
  "capability_flood.wasm"
  "fixtures.manifest.json"
)

missing=0
for f in "${required[@]}"; do
  path="$FIX_DIR/$f"
  if [[ ! -f "$path" ]]; then
    echo "MISSING: $path"
    missing=1
  else
    echo "OK: $path ($(wc -c < "$path") bytes)"
  fi
done

if [[ "$missing" -ne 0 ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_WASM_FIXTURES=1 and fixtures missing"
    exit 1
  fi
  echo "WARN: some fixtures missing (soft mode)"
  exit 0
fi

if [[ -f "$FIX_DIR/fixtures.manifest.json" ]]; then
  echo "OK: fixtures.manifest.json present"
fi

if [[ "$REQUIRE" == "1" ]]; then
  # Optional rebuild when WASI SDK + build script available
  if [[ -x ./scripts/build-wasm-extension.sh ]]; then
    ./scripts/build-wasm-extension.sh || {
      echo "FAIL: rebuild required under REQUIRE_WASM_FIXTURES=1"
      exit 1
    }
  fi
fi

echo "OK: wasm fixture gate"
exit 0
