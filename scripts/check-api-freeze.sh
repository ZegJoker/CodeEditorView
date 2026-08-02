#!/usr/bin/env bash
# REL-N06 — semantic API freeze via digester diagnose + symbol-graph surfaces.
# Rejects name-only inventories that are mere copies of public.txt.
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

if [[ ! -f "$BASELINE_DIR/SEMANTIC-BASELINE.stamp" ]]; then
  echo "FAIL: missing $BASELINE_DIR/SEMANTIC-BASELINE.stamp — run ./scripts/check-api-baseline.sh"
  exit 1
fi
if grep -q 'seeded_from=public_inventory' "$BASELINE_DIR/SEMANTIC-BASELINE.stamp"; then
  echo "FAIL: SEMANTIC-BASELINE.stamp still seeded_from=public_inventory (not real digester/symbol-graph)"
  exit 1
fi

export API_BASELINE_DIR="$TMP/api"
mkdir -p "$API_BASELINE_DIR"
./scripts/extract-public-api.sh "$TMP/api" >/dev/null

# Module search paths for digester dump/diagnose
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
if [[ "${DIGESTER_REUSE_BASELINE:-0}" != "1" ]]; then
  swift build >/dev/null 2>&1 || true
  swift build --target Internal >/dev/null 2>&1 || true
fi
BIN_PATH="$(swift build --show-bin-path 2>/dev/null || echo "$ROOT/.build/arm64-apple-macosx/debug")"
BUILD_ROOT="$BIN_PATH"
MOD_DIR=""
for cand in \
  "$BUILD_ROOT/Modules" \
  "$ROOT/.build/arm64-apple-macosx/debug/Modules"; do
  if [[ -d "$cand" ]]; then MOD_DIR="$cand"; break; fi
done
DIG_I_RSP="$(mktemp)"
if [[ "${DIGESTER_REUSE_BASELINE:-0}" == "1" ]]; then
  # Minimal -I for diagnose-only smoke (no full dump of current SDK)
  {
    [[ -n "$MOD_DIR" ]] && echo "-I" && echo "$MOD_DIR"
    [[ -f "$BUILD_ROOT/Internal.build/module.modulemap" ]] && echo "-I" && echo "$BUILD_ROOT/Internal.build"
  } >"$DIG_I_RSP"
else
  python3 - "$BUILD_ROOT" "$ROOT" "$DIG_I_RSP" <<'PY'
import sys
from pathlib import Path
build = Path(sys.argv[1])
root = Path(sys.argv[2])
out = Path(sys.argv[3])
args = []
mods = build / "Modules"
if mods.is_dir():
    args += ["-I", str(mods)]
seen = set()
for base in [build, root / ".build" / "checkouts"]:
    if not base.is_dir():
        continue
    for mmap in sorted(base.rglob("module.modulemap")):
        if "-tool.build" in str(mmap):
            continue
        try:
            text = mmap.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        name = None
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("module "):
                name = line.split()[1].split("{")[0].strip()
                break
        if not name or name in seen:
            continue
        seen.add(name)
        args += ["-I", str(mmap.parent)]
out.write_text("\n".join(args) + "\n", encoding="utf-8")
PY
fi

fail=0
product_count=0
digester_ran=0
core_require=(CodeEditorCore CodeEditorDocuments CodeEditorView CodeEditorDAP CodeEditorLSP)

is_real_dump() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file() or p.stat().st_size < 200:
    raise SystemExit(1)
d = json.load(open(p, encoding="utf-8"))
root = d.get("ABIRoot") or {}
name = root.get("name") or ""
children = root.get("children") or []
if name in ("", "NO_MODULE") or len(children) == 0:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

while IFS= read -r line; do
  [[ "$line" =~ ^# ]] && continue
  [[ -z "$line" ]] && continue
  product="${line%%$'\t'*}"
  product="$(echo "$product" | awk '{print $1}')"
  [[ -z "$product" ]] && continue
  product_count=$((product_count + 1))

  base_pub="$BASELINE_DIR/${product}.public.txt"
  cur_pub="$TMP/api/${product}.public.txt"
  base_sym="$BASELINE_DIR/${product}.symbols.txt"
  base_dig="$BASELINE_DIR/digester/${product}.json"
  base_graph_dir="$BASELINE_DIR/symbol-graphs/$product"

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

  if [[ ! -f "$base_sym" ]]; then
    case "$product" in
      CodeEditorCore|CodeEditorDocuments|CodeEditorView|CodeEditorDAP|CodeEditorLSP|CodeEditorExtensionHost|CodeEditorTerminalGhostty)
        echo "FAIL: missing symbol-graph baseline $base_sym"
        fail=1
        ;;
      *)
        echo "WARN: no symbols baseline for $product"
        ;;
    esac
  else
    if cmp -s "$base_pub" "$base_sym"; then
      echo "FAIL: $product.symbols.txt is identical to public inventory (not a real symbol-graph surface)"
      fail=1
    elif ! grep -qE 'precise=|decl=|swift\.' "$base_sym" && [[ ! -d "$base_graph_dir" || -z "$(find "$base_graph_dir" -name '*.json' 2>/dev/null | head -1)" ]]; then
      echo "FAIL: $product.symbols.txt lacks symbol-graph markers and no graph JSON"
      fail=1
    else
      echo "OK:   $product symbol-graph surface ($(wc -l <"$base_sym" | tr -d ' ') lines)"
    fi
  fi

  is_core=0
  for c in "${core_require[@]}"; do
    if [[ "$product" == "$c" ]]; then is_core=1; break; fi
  done

  if [[ "$is_core" -eq 1 ]]; then
    if ! is_real_dump "$base_dig"; then
      echo "FAIL: missing/invalid digester baseline dump $base_dig — run ./scripts/check-api-baseline.sh"
      fail=1
    else
      cur_dig="$TMP/api/digester/${product}.json"
      mkdir -p "$(dirname "$cur_dig")"
      # DIGESTER_REUSE_BASELINE=1: validate real dumps + diagnose Core/Documents vs self (fast smoke).
      # Default CI path re-dumps current modules and diagnoses all core products.
      if [[ "${DIGESTER_REUSE_BASELINE:-0}" == "1" ]]; then
        if ! is_real_dump "$base_dig"; then
          echo "FAIL: invalid digester baseline dump $base_dig"
          fail=1
        else
          digester_ran=$((digester_ran + 1))
          case "$product" in
            CodeEditorCore|CodeEditorDocuments|CodeEditorDAP|CodeEditorLSP)
              set +e
              # shellcheck disable=SC2046
              "$DIGESTER" -diagnose-sdk \
                -module "$product" \
                -baseline-path "$base_dig" \
                -input-paths "$base_dig" \
                $(tr '\n' ' ' <"$DIG_I_RSP") \
                -sdk "$SDK_PATH" \
                -compiler-style-diags \
                >"$TMP/${product}.digester.txt" 2>&1
              set -e
              if rg -q 'API breakage' "$TMP/${product}.digester.txt"; then
                echo "FAIL: digester self-diagnose unexpected breakage for $product"
                head -20 "$TMP/${product}.digester.txt" || true
                fail=1
              else
                echo "OK:   digester diagnose $product (baseline self-check, no API breakage)"
              fi
              ;;
            *)
              echo "OK:   digester baseline present for $product (real dump)"
              ;;
          esac
        fi
      else
        set +e
        # shellcheck disable=SC2046
        "$DIGESTER" -dump-sdk -module "$product" \
          $(tr '\n' ' ' <"$DIG_I_RSP") \
          -sdk "$SDK_PATH" \
          -o "$cur_dig" \
          -avoid-location \
          2>"$TMP/api/digester/${product}.dump.log"
        dump_stat=$?
        set -e
        if [[ "$dump_stat" -eq 0 ]] && is_real_dump "$cur_dig"; then
          set +e
          # shellcheck disable=SC2046
          "$DIGESTER" -diagnose-sdk \
            -module "$product" \
            -baseline-path "$base_dig" \
            -input-paths "$cur_dig" \
            $(tr '\n' ' ' <"$DIG_I_RSP") \
            -sdk "$SDK_PATH" \
            -compiler-style-diags \
            >"$TMP/${product}.digester.txt" 2>&1
          set -e
          digester_ran=$((digester_ran + 1))
          if rg -q 'API breakage' "$TMP/${product}.digester.txt"; then
            if [[ "${ALLOW_API_DIFF:-0}" == "1" ]]; then
              echo "WARN: digester diagnose breakage for $product (allowed)"
            else
              echo "FAIL: digester semantic breakage for $product"
              head -40 "$TMP/${product}.digester.txt" || true
              fail=1
            fi
          else
            echo "OK:   digester diagnose $product (no API breakage)"
          fi
        else
          echo "FAIL: could not produce current digester dump for $product"
          head -20 "$TMP/api/digester/${product}.dump.log" 2>/dev/null || true
          fail=1
        fi
      fi
    fi
  elif is_real_dump "$base_dig"; then
    echo "OK:   digester baseline present for $product"
    digester_ran=$((digester_ran + 1))
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

if [[ "$digester_ran" -lt 2 ]]; then
  echo "FAIL: digester must validate for at least 2 products (ran=$digester_ran)"
  fail=1
fi

if [[ -z "$(find "$BASELINE_DIR/digester" -name '*.json' -size +1k 2>/dev/null | head -1)" ]]; then
  echo "FAIL: Baselines/api/digester has no real JSON dumps (>1k)"
  fail=1
fi
if [[ -z "$(find "$BASELINE_DIR/symbol-graphs" -name '*.json' 2>/dev/null | head -1)" ]]; then
  echo "FAIL: Baselines/api/symbol-graphs has no symbol graph JSON"
  fail=1
fi

rm -f "$DIG_I_RSP"
if [[ "$fail" -ne 0 ]]; then
  echo "API freeze check FAILED (regenerate with ALLOW_API_DIFF=1 after review)"
  exit 1
fi
echo "API freeze check passed (digester diagnose + symbol-graph semantic validation)"
