#!/usr/bin/env bash
# Real LSP presence gate (LSP-009 / §13.12).
# Soft by default: report availability.
# Hard when REQUIRE_REAL_LSP=1: fail if sourcekit-lsp missing.
set -euo pipefail
REQUIRE="${REQUIRE_REAL_LSP:-0}"
found=0
for bin in sourcekit-lsp clangd typescript-language-server; do
  if command -v "$bin" >/dev/null 2>&1; then
    echo "OK: found $bin ($($bin --version 2>/dev/null | head -1 || echo present))"
    found=1
  fi
done
if [[ "$found" -eq 0 ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_REAL_LSP=1 but no language server binary on PATH"
    exit 1
  fi
  echo "OK: no real LSP binaries (soft mode)"
  exit 0
fi
# Smoke: sourcekit-lsp --help must succeed when present
if command -v sourcekit-lsp >/dev/null 2>&1; then
  sourcekit-lsp --help >/dev/null
  echo "OK: sourcekit-lsp --help"
fi
exit 0
