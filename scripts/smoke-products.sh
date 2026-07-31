#!/usr/bin/env bash
# Independent build smoke for every public library product.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -d Grammars/src ]]; then
  echo "Grammars/ missing — run ./scripts/ci-bootstrap-grammars.sh first" >&2
  exit 1
fi

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

fail=0
for product in "${PRODUCTS[@]}"; do
  echo "== smoke build --product $product =="
  if ! swift build --product "$product" 2>&1 | tail -3; then
    echo "FAIL: $product"
    fail=1
  else
    echo "OK:   $product"
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "Product smoke FAILED"
  exit 1
fi
echo "All ${#PRODUCTS[@]} products built independently."
