#!/usr/bin/env bash
# Phase 11 / §26 — master qualification gate (hard; no soft-skip / no stubs).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

run() {
  echo
  echo "======== $* ========"
  "$@"
}

run ./scripts/check-product-isolation.sh
run ./scripts/check-docs.sh
run ./scripts/check-feature-profiles.sh
run ./scripts/check-product-scorecards.sh
run ./scripts/check-defects.sh
run ./scripts/check-vacuous-tests.sh
run ./scripts/check-xcode-pin.sh
run ./scripts/check-api-freeze.sh
run ./scripts/check-wasm-fixture.sh
run ./scripts/check-accessibility.sh
run ./scripts/check-security-rc.sh
run ./scripts/check-licenses.sh
run ./scripts/check-perf-budgets.sh
run ./scripts/check-unchecked-sendable.sh
run ./scripts/check-real-lsp.sh
run ./scripts/check-real-dap.sh

# Debug + release smoke of core product
echo
echo "======== swift build debug/release CodeEditorCore ========"
swift build --product CodeEditorCore
swift build -c release --product CodeEditorCore

# Full package test suite with counts
echo
echo "======== full swift test ========"
TEST_LOG="${TMPDIR:-/tmp}/verify-stable-tests.log"
set +e
swift test 2>&1 | tee "$TEST_LOG"
TEST_EC=${PIPESTATUS[0]}
set -e
PASSED="$(rg -o 'Test run with [0-9]+ tests' "$TEST_LOG" | tail -1 | rg -o '[0-9]+' || echo 0)"
echo "TEST_EXIT=$TEST_EC REPORTED_TESTS=$PASSED"
if [[ "$TEST_EC" -ne 0 ]]; then
  echo "FAIL: full swift test exit $TEST_EC"
  exit "$TEST_EC"
fi
if [[ "${PASSED:-0}" == "0" ]]; then
  echo "FAIL: full swift test reported 0 tests"
  exit 1
fi

# Sanitizers / fuzz / soak — hard (real work)
run ./scripts/run-sanitizers.sh
run ./scripts/run-fuzz-smoke.sh
run ./scripts/run-soak-smoke.sh
run ./scripts/run-mutation-smoke.sh

# Release evidence from executable jobs
run ./scripts/generate-release-evidence.sh
run ./scripts/check-release-evidence.sh

# Source archive rehearsal — hard
run ./scripts/export-source-archive-rehearsal.sh

echo
echo "verify-stable: all Phase 11 qualification gates passed (TEST_EXIT=$TEST_EC tests~$PASSED)"
