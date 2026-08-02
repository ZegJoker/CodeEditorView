#!/usr/bin/env bash
# REL-N06 — emit real symbol graphs + digester SDK dumps for ALL public library products.
# No public-inventory seed shortcut. Digester dumps must load real modules (not NO_MODULE).
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

# Hard-require real digester dumps (module must load). Heavy dep graphs may fall back to symbol-graphs.
CORE_DIGESTER=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorDAP
  CodeEditorLSP
  CodeEditorView
)

DIGESTER="$(xcrun --find swift-api-digester 2>/dev/null || true)"
if [[ -z "$DIGESTER" ]]; then
  echo "FAIL: swift-api-digester not found (required for REL-N06 semantic API validation)"
  exit 1
fi

echo "Building package for symbol graphs…"
swift build >/dev/null
# Ensure C/ObjC dependency modules (e.g. TextStory's Internal) are built for digester -I
swift build --target Internal >/dev/null 2>&1 || true

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BIN_PATH="$(swift build --show-bin-path)"
# show-bin-path returns e.g. .build/arm64-apple-macosx/debug (Modules + *.build live here)
BUILD_ROOT="$BIN_PATH"
MOD_DIR=""
for cand in \
  "$BUILD_ROOT/Modules" \
  "$ROOT/.build/arm64-apple-macosx/debug/Modules" \
  "$ROOT/.build/debug/Modules"; do
  if [[ -d "$cand" ]]; then
    MOD_DIR="$cand"
    break
  fi
done
if [[ -z "$MOD_DIR" ]]; then
  MOD_DIR="$(find "$ROOT/.build" -type d -name Modules 2>/dev/null | head -1 || true)"
fi
if [[ -z "$MOD_DIR" ]]; then
  echo "FAIL: no Modules directory under .build for digester -I"
  exit 1
fi
echo "Using module dir: $MOD_DIR"
echo "Using build root: $BUILD_ROOT"

# Digester -I paths as a response file (bash 3.2-safe)
DIG_I_RSP="$(mktemp)"
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
# one flag per line for xargs
out.write_text("\n".join(args) + "\n", encoding="utf-8")
print(f"Digester unique modules for -I: {len(seen)} ({len(args)} argv entries)", flush=True)
PY
echo "Digester -I response: $DIG_I_RSP"

fail=0
graph_ok=0
digest_ok=0

for product in "${PRODUCTS[@]}"; do
  dest="$GRAPH_DIR/$product"
  mkdir -p "$dest"
  find "$dest" -type f ! -name 'emit.log' -delete 2>/dev/null || true
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
      graph_ok=$((graph_ok + 1))
    fi
  else
    echo "FAIL: symbol graph emit failed for $product (see $dest/emit.log)"
    fail=1
  fi

  dig_out="$DIGEST_DIR/${product}.json"
  set +e
  # shellcheck disable=SC2046
  "$DIGESTER" -dump-sdk -module "$product" \
    $(tr '\n' ' ' <"$DIG_I_RSP") \
    -sdk "$SDK_PATH" \
    -o "$dig_out" \
    -avoid-location \
    2>"$DIGEST_DIR/${product}.dump.log"
  dstat=$?
  set -e
  # Validate real dump (not NO_MODULE empty shell)
  real=0
  if [[ "$dstat" -eq 0 && -s "$dig_out" ]]; then
    if python3 - "$dig_out" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
root = d.get("ABIRoot") or {}
name = root.get("name") or ""
children = root.get("children") or []
if name in ("", "NO_MODULE") or len(children) == 0:
    raise SystemExit(1)
raise SystemExit(0)
PY
    then
      real=1
    fi
  fi
  if [[ "$real" -eq 1 ]]; then
    echo "OK:   digester dump $product ($(wc -c <"$dig_out" | tr -d ' ') bytes, real module)"
    digest_ok=$((digest_ok + 1))
  else
    is_core=0
    for c in "${CORE_DIGESTER[@]}"; do
      if [[ "$product" == "$c" ]]; then is_core=1; break; fi
    done
    if [[ "$is_core" -eq 1 ]]; then
      echo "FAIL: digester dump required for core product $product (see $DIGEST_DIR/${product}.dump.log)"
      head -20 "$DIGEST_DIR/${product}.dump.log" || true
      fail=1
    else
      echo "WARN: digester dump failed/empty for $product (non-core)"
    fi
  fi
done

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
            decl = ""
            for frag in (sym.get("declarationFragments") or []):
                if isinstance(frag, dict):
                    decl += frag.get("spelling") or ""
            access = (sym.get("accessLevel") or "")
            if access and access not in ("public", "open"):
                continue
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
    pub = base_root / f"{product}.public.txt"
    if pub.is_file() and out.is_file():
        if pub.read_text(encoding="utf-8") == out.read_text(encoding="utf-8"):
            print(f"FAIL: {product}.symbols.txt identical to public inventory after normalize", file=sys.stderr)
            raise SystemExit(2)
prod_file = base_root / "PRODUCTS.txt"
existing = []
if prod_file.is_file():
    for line in prod_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("#") or not line.strip():
            continue
        existing.append(line.strip().split()[0])
merged = sorted(set(existing) | set(products))
header = [
    "# API baseline products — regenerated by scripts/check-api-baseline.sh",
    "# Includes symbol-graph normalized surfaces (REL-N06)",
]
prod_file.write_text("\n".join(header + merged) + "\n", encoding="utf-8")
print(f"OK:   PRODUCTS.txt ({len(merged)} products)")
PY

./scripts/extract-public-api.sh "$BASELINE_DIR" >/dev/null || true

{
  echo "# Digester / symbol-graph baseline stamp"
  date -u +"# %Y-%m-%dT%H:%M:%SZ"
  echo "digester=$DIGESTER"
  echo "graph_dir=$GRAPH_DIR"
  echo "digest_dir=$DIGEST_DIR"
  echo "graph_products=$graph_ok"
  echo "digester_products=$digest_ok"
  echo "source=swift-symbolgraph+api-digester"
} >"$BASELINE_DIR/SEMANTIC-BASELINE.stamp"

if [[ "$fail" -ne 0 ]]; then
  echo "API baseline check FAILED"
  exit 1
fi
if [[ "$graph_ok" -lt 10 ]]; then
  echo "FAIL: too few symbol-graph products ($graph_ok)"
  exit 1
fi
if [[ "$digest_ok" -lt 4 ]]; then
  echo "FAIL: too few real digester dumps ($digest_ok)"
  exit 1
fi
rm -f "$DIG_I_RSP"
echo "API baseline check complete (symbol graphs=$graph_ok digester dumps=$digest_ok)"
