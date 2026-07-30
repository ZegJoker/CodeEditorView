#!/usr/bin/env bash
# Verifies Phase 13 documentation / guide inventory.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0
require() {
  if [[ ! -f "$1" ]]; then
    echo "FAIL: missing $1"
    fail=1
  else
    echo "OK:   $1"
  fi
}

echo "== Guides =="
require Docs/Guides/API-STABILITY.md
require Docs/Guides/API-AUDIT.md
require Docs/Guides/PRODUCT-SELECTION.md
require Docs/Guides/MIGRATION-1.0.md
require Docs/Guides/EXTENSION-AUTHORING.md
require Docs/Architecture/ADR-012-1.0-stability.md
require Docs/Architecture/PHASE13-NOTES.md
require CHANGELOG.md
require README.md

echo "== DocC landings =="
for mod in \
  CodeEditorCore CodeEditorDocuments CodeEditorCommands CodeEditorWorkspace \
  CodeEditorWorkbench CodeEditorView CodeEditorLanguageSupport CodeEditorLanguageServices \
  CodeEditorExtensions CodeEditorExtensionHost CodeEditorLSP CodeEditorSearch \
  CodeEditorTasks CodeEditorTerminal CodeEditorSourceControl CodeEditorTreeSitter \
  CodeEditorLanguageSwift CodeEditorLanguageJSON CodeEditorLanguages
do
  require "Sources/${mod}/Documentation.docc/Documentation.md"
done

echo "== Examples =="
require Examples/SmallEditor/Package.swift
require Examples/FullWorkbench/Package.swift
require Examples/CodeEditorViewDemo/Package.swift

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Documentation inventory checks FAILED."
  exit 1
fi
echo
echo "All documentation inventory checks passed."
