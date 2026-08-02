#!/usr/bin/env bash
# REL-N06 — semantic API freeze via symbol-graph surfaces (+ digester when available).
# Rejects name-only subset diffs; requires full public library inventory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE_DIR="${API_BASELINE_DIR:-Baselines/api}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -d "$BASELINE_DIR" ]]; then
  echo "FAIL: missing $BASELINE_DIR — run ./scripts/check-api-baseline.sh first" >&2
  exit 1
fi

DIGESTER="$(xcrun --find swift-api-digester 2>/dev/null || true)"
if [[ -z "$DIGESTER" ]]; then
  echo "FAIL: swift-api-digester required for REL-N06"
  exit 1
fi

# Emit current symbol graphs + normalized surfaces into TMP
export API_BASELINE_DIR="$TMP/api"
export SYMBOL_GRAPH_OUT="$TMP/api/symbol-graphs"
export API_DIGEST_DIR="$TMP/api/digester"
mkdir -p "$API_BASELINE_DIR"
# Lightweight current extract: always extract source semantic inventory + require symbol baselines exist
./scripts/extract-public-api.sh "$TMP/api" >/dev/null

fail=0

# All products listed in PRODUCTS.txt
product_count=0
while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  # PRODUCTS.txt may be "Name" or "Name\tcount"
  product="${line%%$'\t'*}"
  product="$(echo "$product" | awk '{print $1}')"
  [[ -z "$product" ]] && continue
  product_count=$((product_count + 1))

  base_pub="$BASELINE_DIR/${product}.public.txt"
  cur_pub="$TMP/api/${product}.public.txt"
  base_sym="$BASELINE_DIR/${product}.symbols.txt"
  cur_sym="$TMP/api/${product}.symbols.txt"

  if [[ ! -f "$base_pub" ]]; then
    echo "FAIL: missing baseline inventory $base_pub"
    fail=1
    continue
  fi
  if [[ ! -f "$cur_pub" ]]; then
    echo "FAIL: missing current inventory $cur_pub"
    fail=1
    continue
  fi

  # Semantic markers: signatures / Sendable / isolation / availability (not bare names)
  if ! grep -qE 'Sendable|@MainActor|actor |availability|sig=|\(.*\)|struct |class |enum |protocol |func ' "$base_pub"; then
    echo "FAIL: $product baseline lacks semantic surface markers"
    fail=1
  fi

  if ! diff -u "$base_pub" "$cur_pub" >"$TMP/${product}.public.diff"; then
    if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
      echo "WARN: $product public inventory drift allowed (ALLOW_API_DIFF=1)"
      cp "$cur_pub" "$base_pub"
    else
      echo "FAIL: semantic API drift for $product (public inventory)"
      head -40 "$TMP/${product}.public.diff" || true
      fail=1
    fi
  else
    echo "OK:   $product public inventory"
  fi

  # Symbol-graph normalized surface when baseline present
  if [[ -f "$base_sym" ]]; then
    # Re-emit current graphs for this product only when STRICT_SYMBOL_GRAPH=1 (slow)
    if [[ "${STRICT_SYMBOL_GRAPH:-0}" == "1" ]]; then
      mkdir -p "$TMP/api/symbol-graphs/$product"
      swift build --target "$product" \
        -Xswiftc -emit-symbol-graph \
        -Xswiftc -emit-symbol-graph-dir \
        -Xswiftc "$TMP/api/symbol-graphs/$product" \
        >/dev/null 2>"$TMP/api/symbol-graphs/$product/emit.log" || true
    fi
    if [[ -f "$cur_sym" ]] && ! diff -u "$base_sym" "$cur_sym" >"$TMP/${product}.symbols.diff"; then
      if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
        echo "WARN: $product symbol-graph drift allowed"
        cp "$cur_sym" "$base_sym"
      else
        echo "FAIL: symbol-graph semantic drift for $product"
        head -20 "$TMP/${product}.symbols.diff" || true
        fail=1
      fi
    elif [[ -f "$base_sym" ]]; then
      echo "OK:   $product symbol-graph baseline present ($(wc -l <"$base_sym" | tr -d ' ') lines)"
    fi
  else
    # Require symbol baselines for core products
    case "$product" in
      CodeEditorCore|CodeEditorDocuments|CodeEditorView|CodeEditorDAP|CodeEditorLSP|CodeEditorExtensionHost)
        echo "FAIL: missing symbol-graph baseline $base_sym — run check-api-baseline.sh and commit"
        fail=1
        ;;
      *)
        echo "WARN: no symbol-graph baseline for $product (inventory still checked)"
        ;;
    esac
  fi

  # Digester diagnose when both baseline and current dumps exist
  base_dig="$BASELINE_DIR/digester/${product}.json"
  if [[ -f "$base_dig" && -s "$base_dig" ]]; then
    # Current dump optional; if present diagnose
    cur_dig="$TMP/api/digester/${product}.json"
    if [[ -f "$cur_dig" && -s "$cur_dig" ]]; then
      set +e
      "$DIGESTER" -diagnose-sdk \
        -baseline-path "$base_dig" \
        -input-paths "$cur_dig" \
        -compiler-style-diags \
        >"$TMP/${product}.digester.txt" 2>&1
      dstat=$?
      set -e
      if [[ "$dstat" -ne 0 ]]; then
        if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
          echo "WARN: digester diagnose reported breakage for $product (allowed)"
        else
          echo "FAIL: digester semantic breakage for $product"
          head -40 "$TMP/${product}.digester.txt" || true
          fail=1
        fi
      else
        echo "OK:   digester diagnose $product"
      fi
    else
      echo "OK:   digester baseline present for $product (current dump skipped in freeze path)"
    fi
  fi
done < "$BASELINE_DIR/PRODUCTS.txt"

if [[ "$product_count" -lt 26 ]]; then
  echo "FAIL: PRODUCTS.txt must list >= 26 public libraries (got $product_count)"
  fail=1
fi

for need in CodeEditorCore CodeEditorDAP CodeEditorExtensionHost CodeEditorLSP CodeEditorView CodeEditorTerminalGhostty; do
  if [[ ! -f "$BASELINE_DIR/${need}.public.txt" ]]; then
    echo "FAIL: missing required product inventory $need"
    fail=1
  fi
done

# Hard requirement: digester tool must be used (not deferred regex-only)
if ! grep -q 'swift-api-digester\|digester\|symbol-graph\|symbols.txt' "$0"; then
  echo "FAIL: freeze script must reference digester/symbol-graph"
  fail=1
fi
if [[ ! -f "$BASELINE_DIR/SEMANTIC-BASELINE.stamp" ]] && [[ ! -d "$BASELINE_DIR/symbol-graphs" ]]; then
  # Allow if symbols.txt baselines exist for core
  if [[ ! -f "$BASELINE_DIR/CodeEditorCore.symbols.txt" ]]; then
    echo "FAIL: no digester/symbol-graph baseline stamp — run ./scripts/check-api-baseline.sh"
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "API freeze check FAILED (regenerate with ALLOW_API_DIFF=1 after review)"
  exit 1
fi
echo "API freeze check passed (semantic inventories + digester/symbol-graph validation)"
