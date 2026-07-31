#!/usr/bin/env bash
# Emit Swift symbol graphs for each public library product (Phase 0 baseline helper).
# Full API-diff CI lands in Phase 1; this script documents the local inventory path.
#
# Usage (from repo root):
#   ./scripts/dump-symbol-graphs.sh
#   ./scripts/dump-symbol-graphs.sh CodeEditorCore CodeEditorExtensions
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${SYMBOL_GRAPH_OUT:-.build/symbol-graphs}"
mkdir -p "$OUT"

PRODUCTS=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorCommands
  CodeEditorWorkspace
  CodeEditorWorkbench
  CodeEditorView
  CodeEditorLanguageSupport
  CodeEditorLanguageServices
  CodeEditorExtensions
  CodeEditorExtensionHost
  CodeEditorLSP
  CodeEditorSearch
  CodeEditorTasks
  CodeEditorTerminal
  CodeEditorSourceControl
  CodeEditorTreeSitter
  CodeEditorLanguageSwift
  CodeEditorLanguageJSON
  CodeEditorLanguages
)

if [[ "$#" -gt 0 ]]; then
  PRODUCTS=("$@")
fi

if [[ ! -d Grammars/src ]]; then
  echo "Grammars/ missing. Run: ./scripts/update-grammars.sh" >&2
  exit 1
fi

echo "Building package (required for symbol graph emission)…"
swift build 2>&1 | tail -5

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
TARGET_TRIPLE="$(swift -print-target-info 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target"]["triple"])' 2>/dev/null || echo "arm64-apple-macosx15.0")"

for product in "${PRODUCTS[@]}"; do
  dest="$OUT/$product"
  mkdir -p "$dest"
  echo "== $product → $dest =="
  # Prefer swift build -emit-symbol-graph when available via SPM.
  if swift build --target "$product" \
      -Xswiftc -emit-symbol-graph \
      -Xswiftc -emit-symbol-graph-dir \
      -Xswiftc "$dest" 2>"$dest/emit.log"; then
    count="$(find "$dest" -name '*.json' | wc -l | tr -d ' ')"
    echo "   emitted $count symbol-graph JSON file(s)"
  else
    echo "   WARN: symbol graph emit failed for $product (see $dest/emit.log)"
  fi
done

echo
echo "Symbol graphs under $OUT"
echo "Summarize public decls (optional): jq -r '.symbols[].kind.identifier' $OUT/*/*.json | sort | uniq -c"
