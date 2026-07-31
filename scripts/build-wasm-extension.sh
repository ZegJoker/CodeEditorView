#!/usr/bin/env bash
# Build a Swift extension product for wasm32 using the pinned WASI SDK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PIN_FILE="Docs/Architecture/WASI-SDK.pin"
PIN="$(grep -v '^#' "$PIN_FILE" | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
PRODUCT="${1:-ConformanceExtensionGuest}"
OUT_DIR="${2:-.codeeditor/build/wasm}"
mkdir -p "$OUT_DIR"

if ! swift sdk list 2>/dev/null | grep -Fqi "$PIN"; then
  echo "WARN: pinned WASI SDK '$PIN' not installed; cannot cross-compile."
  echo "      Install per Docs/Architecture/TOOLCHAIN.md"
  if [[ "${WASM_BUILD_REQUIRED:-0}" == "1" ]]; then
    exit 1
  fi
  exit 0
fi

echo "Building $PRODUCT with --swift-sdk $PIN"
swift build -c release --swift-sdk "$PIN" --product "$PRODUCT" 2>&1 | tee "$OUT_DIR/build.log"
# Locate artifact (layout varies)
ART="$(find .build -name "$PRODUCT.wasm" -o -name "$PRODUCT" 2>/dev/null | head -1 || true)"
if [[ -z "$ART" ]]; then
  echo "WARN: no wasm artifact found after build (Swift may emit different name)"
  ART=""
fi
SHA="n/a"
if [[ -n "$ART" && -f "$ART" ]]; then
  cp "$ART" "$OUT_DIR/extension.wasm"
  SHA="$(shasum -a 256 "$OUT_DIR/extension.wasm" | awk '{print $1}')"
fi
cat > "$OUT_DIR/wasm-repro.json" << JSON
{
  "swift_sdk": "$PIN",
  "product": "$PRODUCT",
  "artifact_sha256": "$SHA",
  "schema_hash_note": "see ExtensionMethodCatalog.schemaHash",
  "flags": "-c release --swift-sdk $PIN"
}
JSON
echo "OK: repro written $OUT_DIR/wasm-repro.json"
