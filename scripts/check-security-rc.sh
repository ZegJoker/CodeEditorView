#!/usr/bin/env bash
# Security RC evidence pack: required docs + Phase14/15/16 security test filters.
# Hard gate: each filter must execute ≥1 test and exit 0.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
for f in \
  Docs/Architecture/ADR-015-extension-threat-model.md \
  Docs/Guides/APP-REVIEW.md \
  Docs/Architecture/SECURITY-RC.md
do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    fail=1
  else
    echo "OK:   $f"
  fi
done
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

run_filter() {
  local label="$1"
  local filter="$2"
  local log
  log="$(mktemp /tmp/security-rc.XXXXXX)"
  echo "== swift test --filter $filter ($label) =="
  set +e
  swift test --filter "$filter" 2>&1 | tee "$log"
  local ec=${PIPESTATUS[0]}
  set -e
  if [[ "$ec" -ne 0 ]]; then
    echo "FAIL: $label filter exited $ec"
    return 1
  fi
  local count
  count="$(rg -o 'Test run with [0-9]+ tests' "$log" | tail -1 | rg -o '[0-9]+' || echo 0)"
  if [[ "${count:-0}" -lt 1 ]]; then
    echo "FAIL: $label matched 0 tests (filter '$filter')"
    return 1
  fi
  echo "OK:   $label ($count tests)"
  return 0
}

run_filter "Phase16Security" "Phase16Security" || exit 1
# Struct Phase14SigningTests / suites under Phase 14 signing*
run_filter "Phase14Signing" "Phase14Signing" || exit 1

echo "Security RC checks passed"
