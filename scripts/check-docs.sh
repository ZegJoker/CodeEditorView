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
require Docs/Architecture/ADR-013-stable-gate.md
require Docs/Architecture/ADR-014-swift-first-extensions.md
require Docs/Architecture/ADR-015-extension-threat-model.md
require Docs/Architecture/ADR-016-platform-profiles.md
require Docs/Architecture/CompatibilityProfile.toml
require Docs/Architecture/PRODUCT-OWNERS.md
require Docs/Architecture/EXTENSION-API-INVENTORY.md
require Docs/Architecture/PHASE13-NOTES.md
require Docs/Architecture/PHASE0-NOTES.md
require Docs/Architecture/PHASE1-NOTES.md
require Docs/Architecture/PHASE2-NOTES.md
require Docs/Architecture/PHASE3-NOTES.md
require Docs/Architecture/PHASE4-NOTES.md
require Docs/Architecture/PHASE5-NOTES.md
require Docs/Architecture/PHASE6-NOTES.md
require Docs/Architecture/PHASE7-NOTES.md
require Docs/Architecture/PHASE8-NOTES.md
require Docs/Architecture/PHASE9-NOTES.md
require Docs/Architecture/PHASE10-NOTES.md
require Docs/Architecture/PHASE11-NOTES.md
require Docs/Architecture/ADR-017-core-wasm-abi-v1.md
require Docs/Architecture/VIEW-PUBLIC-API.md
require Docs/Architecture/TOOLCHAIN.md
require scripts/grammar-inventory.json
require Docs/Architecture/WASI-SDK.pin
require CHANGELOG.md
require README.md
require .github/workflows/ci.yml

echo "== DocC landings =="
for mod in \
  CodeEditorCore CodeEditorDocuments CodeEditorCommands CodeEditorWorkspace \
  CodeEditorWorkbench CodeEditorView CodeEditorLanguageSupport CodeEditorLanguageServices \
  CodeEditorExtensionAPI CodeEditorExtensionProtocol CodeEditorExtensionGuest CodeEditorWasmEngine CodeEditorWasmEngineWasmKit CodeEditorExtensionWasmGuest CodeEditorExtensions CodeEditorExtensionHost CodeEditorLSP CodeEditorSearch \
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
