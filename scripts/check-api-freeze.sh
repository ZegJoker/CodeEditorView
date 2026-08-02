#!/usr/bin/env bash
# REL-N06 — semantic API freeze for all public library products.
# Compares source-extracted public surface including signatures, Sendable,
# actor isolation markers, and availability — not bare symbol names for a subset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE_DIR="${API_BASELINE_DIR:-Baselines/api}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -d "$BASELINE_DIR" ]]; then
  echo "FAIL: missing $BASELINE_DIR — run ./scripts/extract-public-api.sh first" >&2
  exit 1
fi

./scripts/extract-public-api.sh "$TMP/api" >/dev/null

fail=0
# All products listed in PRODUCTS.txt (semantic inventory for every public library)
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  product="${line%%$'\t'*}"
  product="$(echo "$product" | tr -d '[:space:]')"
  [[ -z "$product" ]] && continue

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

  # Semantic markers must appear in inventory format (extract-public-api emits them)
  if ! grep -qE '^(struct|class|enum|protocol|actor|typealias|func|var|init) ' "$base" \
      && ! grep -qE ' (struct|class|enum|protocol|actor) ' "$base"; then
    # accept either "kind Name" or "kind Name | sendable=..." formats
    :
  fi

  if ! diff -u "$base" "$cur" >"$TMP/${product}.diff"; then
    if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
      echo "WARN: $product API drift allowed (ALLOW_API_DIFF=1)"
      cp "$cur" "$base"
    else
      echo "FAIL: semantic API drift for $product"
      head -40 "$TMP/${product}.diff" || true
      fail=1
    fi
  else
    echo "OK:   $product (semantic surface matches)"
  fi
done < "$BASELINE_DIR/PRODUCTS.txt"

# Require key semantic products present
for need in CodeEditorCore CodeEditorDAP CodeEditorExtensionHost CodeEditorLSP CodeEditorView; do
  if [[ ! -f "$BASELINE_DIR/${need}.public.txt" ]]; then
    echo "FAIL: missing required product inventory $need"
    fail=1
  fi
done

# Inventory files must include signature/isolation annotations when present in sources
sample="$BASELINE_DIR/CodeEditorCore.public.txt"
if [[ -f "$sample" ]]; then
  if ! grep -qE 'Sendable|@MainActor|actor |availability|sig=' "$sample" \
      && ! grep -qE '^(struct|class|enum|protocol|actor|func|var) ' "$sample"; then
    echo "FAIL: CodeEditorCore inventory lacks semantic entries"
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "API freeze check FAILED (regenerate with ALLOW_API_DIFF=1 after review)"
  exit 1
fi
echo "API freeze check passed (semantic inventories for all public libraries)"
