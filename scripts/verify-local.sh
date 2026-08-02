#!/usr/bin/env bash
# Local mirror of key CI gates (macOS developer machine).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "======== Xcode pin ========"
./scripts/check-xcode-pin.sh

echo "======== grammar pins + committed sources (PKG-001) ========"
./scripts/verify-grammars.sh

echo "======== isolation ========"
./scripts/check-product-isolation.sh

echo "======== docs ========"
./scripts/check-docs.sh

echo "======== licenses ========"
./scripts/check-licenses.sh

echo "======== format (hard) ========"
./scripts/check-format.sh

echo "======== WASI pin (hard) ========"
./scripts/check-wasi-sdk.sh

echo "======== Phase 16 RC gates (subset without full examples) ========"
./scripts/check-product-scorecards.sh
DEFECTS_ALLOW_OPEN=1 ./scripts/check-defects.sh
./scripts/check-api-freeze.sh
./scripts/check-accessibility.sh

echo "======== swift test ========"
swift test

echo
echo "verify-local: all gates passed (for full RC use ./scripts/verify-rc.sh)"
echo "Phase 1 extras: ./scripts/export-source-archive-rehearsal.sh && ./scripts/check-examples.sh"
