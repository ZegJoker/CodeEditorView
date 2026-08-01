#!/usr/bin/env bash
# PKG-001: Grammars are committed under Packages/CodeEditorGrammars.
# CI only verifies pins + checksums — no network materialization.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/check-grammar-pins.sh
./scripts/verify-grammars.sh
