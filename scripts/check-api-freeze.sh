#!/usr/bin/env bash
# Fail if public API surface for Stable products drifts from committed baselines.
# Set ALLOW_API_DIFF=1 to refresh intentionally after reviewing extract-public-api.sh output.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE_DIR="${API_BASELINE_DIR:-Baselines/api}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stable-tier products under freeze (API-STABILITY.md)
STABLE_PRODUCTS=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorLanguageSupport
  CodeEditorView
  CodeEditorTreeSitter
  CodeEditorLanguageSwift
  CodeEditorLanguageJSON
  CodeEditorLanguages
)

if [[ ! -d "$BASELINE_DIR" ]]; then
  echo "FAIL: missing $BASELINE_DIR — run ./scripts/extract-public-api.sh first" >&2
  exit 1
fi

./scripts/extract-public-api.sh "$TMP/api" >/dev/null

fail=0
for product in "${STABLE_PRODUCTS[@]}"; do
  base="$BASELINE_DIR/${product}.public.txt"
  cur="$TMP/api/${product}.public.txt"
  if [[ ! -f "$base" ]]; then
    echo "FAIL: missing baseline $base"
    fail=1
    continue
  fi
  if [[ ! -f "$cur" ]]; then
    echo "FAIL: missing current inventory $cur"
    fail=1
    continue
  fi
  if ! diff -u "$base" "$cur" >"$TMP/${product}.diff"; then
    if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
      echo "WARN: $product API drift allowed (ALLOW_API_DIFF=1)"
      cp "$cur" "$base"
    else
      echo "FAIL: Stable API drift for $product"
      head -40 "$TMP/${product}.diff" || true
      fail=1
    fi
  else
    echo "OK:   $product (frozen surface matches)"
  fi
done

# Ensure all product baseline files exist
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  p="${line%%$'\t'*}"
  if [[ ! -f "$BASELINE_DIR/${p}.public.txt" ]]; then
    echo "FAIL: missing inventory for $p"
    fail=1
  fi
done < "$BASELINE_DIR/PRODUCTS.txt"

if [[ "$fail" -ne 0 ]]; then
  echo "API freeze check FAILED (regenerate with ALLOW_API_DIFF=1 after review)"
  exit 1
fi
echo "API freeze check passed"
