#!/usr/bin/env bash
# §26.6 fuzz/adversarial smoke — hard. Must execute matching tests successfully.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="${TMPDIR:-/tmp}/fuzz-smoke.log"
set +e
swift test --filter 'malformed|Malformed|adversarial|Fuzz|FramingFuzz' 2>&1 | tee "$LOG"
EC=${PIPESTATUS[0]}
set -e

if [[ "$EC" -ne 0 ]]; then
  echo "FAIL: fuzz-smoke tests exited $EC"
  exit "$EC"
fi

# Require at least one suite/test executed (not an empty filter success)
if ! rg -q 'Test run with [1-9][0-9]* tests|passed' "$LOG"; then
  # Swift Testing prints "Test run with N tests in M suites"
  if ! rg -q 'Test run with' "$LOG"; then
    echo "FAIL: fuzz-smoke produced no test run output"
    exit 1
  fi
fi
COUNT="$(rg -o 'Test run with [0-9]+ tests' "$LOG" | tail -1 | rg -o '[0-9]+' || echo 0)"
if [[ "${COUNT:-0}" -lt 1 ]]; then
  echo "FAIL: fuzz-smoke matched 0 tests (filter too narrow or missing adversarial coverage)"
  exit 1
fi

echo "OK:   fuzz-smoke completed ($COUNT tests)"
exit 0
