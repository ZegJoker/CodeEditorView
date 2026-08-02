#!/usr/bin/env bash
# Phase 16 release-candidate master gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "======== product isolation ========"
./scripts/check-product-isolation.sh

echo "======== docs inventory ========"
./scripts/check-docs.sh

echo "======== feature profiles ========"
./scripts/check-feature-profiles.sh

echo "======== product scorecards ========"
./scripts/check-product-scorecards.sh

echo "======== defects (no open P0/P1) ========"
./scripts/check-defects.sh

echo "======== API freeze (Stable products) ========"
./scripts/check-api-freeze.sh

echo "======== accessibility ========"
./scripts/check-accessibility.sh

echo "======== security RC docs ========"
for f in Docs/Architecture/SECURITY-RC.md Docs/Guides/APP-REVIEW.md Docs/Architecture/ADR-015-extension-threat-model.md; do
  [[ -f "$f" ]] || { echo "FAIL: missing $f"; exit 1; }
done
echo "OK:   security docs present"

echo "======== Phase16 tests ========"
swift test --filter Phase16

echo "======== examples resolve ========"
./scripts/check-examples.sh

echo "======== Phase 11 vacuous / evidence hooks ========"
./scripts/check-vacuous-tests.sh
./scripts/check-perf-budgets.sh
./scripts/check-unchecked-sendable.sh
./scripts/check-licenses.sh

echo
echo "verify-rc: Phase 16 RC gates + Phase 11 hooks passed"
echo "For full §26 qualification run: ./scripts/verify-stable.sh"
