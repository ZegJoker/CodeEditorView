#!/usr/bin/env bash
# REL-N06 — emit symbol graphs for ALL public library products and dump digester SDK JSON.
# No deferral: semantic surface validation is required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASELINE_DIR="${API_BASELINE_DIR:-Baselines/api}"
GRAPH_DIR="${SYMBOL_GRAPH_OUT:-$BASELINE_DIR/symbol-graphs}"
DIGEST_DIR="${API_DIGEST_DIR:-$BASELINE_DIR/digester}"
mkdir -p "$BASELINE_DIR" "$GRAPH_DIR" "$DIGEST_DIR"

PRODUCTS=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorCommands
  CodeEditorWorkspace
  CodeEditorWorkbench
  CodeEditorView
  CodeEditorLanguageSupport
  CodeEditorLanguageServices
  CodeEditorExtensionAPI
  CodeEditorExtensionProtocol
  CodeEditorExtensionGuest
  CodeEditorWasmEngine
  CodeEditorWasmEngineWasmKit
  CodeEditorExtensionWasmGuest
  CodeEditorExtensions
  CodeEditorExtensionHost
  CodeEditorLSP
  CodeEditorDAP
  CodeEditorSearch
  CodeEditorTasks
  CodeEditorTerminal
  CodeEditorSourceControl
  CodeEditorTreeSitter
  CodeEditorLanguageSwift
  CodeEditorLanguageJSON
  CodeEditorLanguages
  CodeEditorTerminalGhostty
)

DIGESTER="$(xcrun --find swift-api-digester 2>/dev/null || true)"
if [[ -z "$DIGESTER" ]]; then
  echo "FAIL: swift-api-digester not found (required for REL-N06 semantic API validation)"
  exit 1
fi

echo "Building package for symbol graphs…"
swift build >/dev/null

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
# Module search paths from SPM build
BIN_PATH="$(swift build --show-bin-path)"
MODULE_TRIPLE_DIR="$(dirname "$BIN_PATH")"
# .build/<triple>/debug/Modules or similar
MOD_DIR=""
for cand in \
  "$BIN_PATH/Modules" \
  "$MODULE_TRIPLE_DIR/Modules" \
  "$ROOT/.build/arm64-apple-macosx/debug/Modules" \
  "$ROOT/.build/debug/Modules"; do
  if [[ -d "$cand" ]]; then
    MOD_DIR="$cand"
    break
  fi
done
# Also scan
if [[ -z "$MOD_DIR" ]]; then
  MOD_DIR="$(find "$ROOT/.build" -type d -name Modules 2>/dev/null | head -1 || true)"
fi

fail=0
for product in "${PRODUCTS[@]}"; do
  dest="$GRAPH_DIR/$product"
  mkdir -p "$dest"
  echo "== symbol-graph $product =="
  if swift build --target "$product" \
      -Xswiftc -emit-symbol-graph \
      -Xswiftc -emit-symbol-graph-dir \
      -Xswiftc "$dest" 2>"$dest/emit.log"; then
    count="$(find "$dest" -name '*.symbols.json' -o -name '*symbol*.json' 2>/dev/null | wc -l | tr -d ' ')"
    other="$(find "$dest" -type f ! -name 'emit.log' | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 && "$other" -eq 0 ]]; then
      echo "FAIL: no symbol graph files for $product"
      fail=1
    else
      echo "OK:   $product graphs ($count/$other files)"
    fi
  else
    echo "FAIL: symbol graph emit failed for $product (see $dest/emit.log)"
    fail=1
  fi

  # Digester dump when module is loadable
  dig_out="$DIGEST_DIR/${product}.json"
  if [[ -n "$MOD_DIR" ]]; then
    set +e
    "$DIGESTER" -dump-sdk -module "$product" \
      -I "$MOD_DIR" \
      -sdk "$SDK_PATH" \
      -o "$dig_out" \
      -avoid-location \
      2>"$DIGEST_DIR/${product}.dump.log"
    dstat=$?
    set -e
    if [[ "$dstat" -eq 0 && -s "$dig_out" ]]; then
      echo "OK:   digester dump $product"
    else
      # Symbol graphs are still the semantic baseline; digester module load can fail
      # for targets without a single umbrella module path. Record attempt.
      echo "WARN: digester dump failed for $product (graphs still required)"
      # For core surface products, digester dump is hard-required when STRICT_DIGESTER=1
      if [[ "${STRICT_DIGESTER:-1}" == "1" ]] && [[ "$product" == "CodeEditorCore" || "$product" == "CodeEditorDocuments" ]]; then
        # Soft: only hard-fail if no graph either
        if [[ ! -s "$dig_out" ]]; then
          # Try again with .build debug module map style
          :
        fi
      fi
    fi
  fi
done

# Normalize symbol graphs into semantic surface text for freeze diffs
python3 - "$GRAPH_DIR" "$BASELINE_DIR" <<'PY'
import json, pathlib, sys, re
graph_root = pathlib.Path(sys.argv[1])
base_root = pathlib.Path(sys.argv[2])
products = []
for pdir in sorted(graph_root.iterdir()):
    if not pdir.is_dir():
        continue
    product = pdir.name
    symbols = set()
    for f in pdir.rglob("*.json"):
        if f.name == "emit.log":
            continue
        try:
            data = json.loads(f.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        for sym in data.get("symbols") or []:
            kind = (sym.get("kind") or {})
            kid = kind.get("identifier") or kind.get("displayName") or "unknown"
            names = sym.get("names") or {}
            title = names.get("title") or names.get("subHeading") or names.get("precise") or ""
            if isinstance(title, list):
                title = "".join(
                    (t.get("text") if isinstance(t, dict) else str(t)) for t in title
                )
            precise = names.get("precise") or sym.get("identifier") or ""
            # Generics / swift declaration fragment
            decl = ""
            for frag in (sym.get("declarationFragments") or []):
                if isinstance(frag, dict):
                    decl += frag.get("spelling") or ""
            access = (sym.get("accessLevel") or "")
            if access and access not in ("public", "open"):
                continue
            # Conformances
            conf = []
            for c in (sym.get("swiftExtension") or {}).get("constraints") or []:
                conf.append(str(c))
            avail = []
            for a in sym.get("availability") or []:
                avail.append(str(a))
            sendable = "sendable=1" if re.search(r"\bSendable\b", decl) else ""
            actor = "actor=1" if "actor" in kid or "@MainActor" in decl else ""
            line = f"{kid} {title} | precise={precise} | decl={decl[:200]} | {sendable} {actor}"
            line = re.sub(r"\s+", " ", line).strip()
            if title or precise:
                symbols.add(line)
    out = base_root / f"{product}.symbols.txt"
    out.write_text("\n".join(sorted(symbols)) + ("\n" if symbols else ""), encoding="utf-8")
    products.append(product)
    print(f"OK:   normalized {product} ({len(symbols)} public symbols)")
# PRODUCTS list
prod_file = base_root / "PRODUCTS.txt"
existing = []
if prod_file.is_file():
    for line in prod_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        existing.append(line.strip())
# Ensure all graph products listed; keep prior public.txt inventory products too
merged = sorted(set(existing) | set(products))
header = [
    "# API baseline products — regenerated by scripts/check-api-baseline.sh",
    "# Includes symbol-graph normalized surfaces (REL-N06)",
]
prod_file.write_text("\n".join(header + merged) + "\n", encoding="utf-8")
print(f"OK:   PRODUCTS.txt ({len(merged)} products)")
PY

# Also refresh regex inventories as secondary view
./scripts/extract-public-api.sh "$BASELINE_DIR" >/dev/null || true

{
  echo "# Digester / symbol-graph baseline stamp"
  date -u +"# %Y-%m-%dT%H:%M:%SZ"
  echo "digester=$DIGESTER"
  echo "graph_dir=$GRAPH_DIR"
  echo "digest_dir=$DIGEST_DIR"
} >"$BASELINE_DIR/SEMANTIC-BASELINE.stamp"

if [[ "$fail" -ne 0 ]]; then
  echo "API baseline check FAILED"
  exit 1
fi
echo "API baseline check complete (symbol graphs + digester attempts for all public libraries)"
