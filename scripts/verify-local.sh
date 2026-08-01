#!/usr/bin/env bash
# Local mirror of key CI gates (macOS developer machine).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "======== grammar pins + hermetic verify ========"
./scripts/check-grammar-pins.sh
if [[ ! -d Grammars/src/swift ]]; then
  echo "======== bootstrap grammars ========"
  ./scripts/update-grammars.sh
fi
./scripts/verify-grammars.sh

echo "======== isolation ========"
./scripts/check-product-isolation.sh

echo "======== docs ========"
./scripts/check-docs.sh

echo "======== licenses ========"
./scripts/check-licenses.sh

echo "======== format ========"
./scripts/check-format.sh

echo "======== Phase 16 RC gates (subset without full examples) ========"
./scripts/check-product-scorecards.sh
./scripts/check-defects.sh
./scripts/check-api-freeze.sh
./scripts/check-accessibility.sh

echo "======== swift test ========"
swift test

echo
echo "verify-local: all gates passed (for full RC use ./scripts/verify-rc.sh)"
