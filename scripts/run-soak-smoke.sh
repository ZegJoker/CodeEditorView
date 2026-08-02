#!/usr/bin/env bash
# §26.6 soak smoke — deterministic multi-iteration hard gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ITERS="${SOAK_ITERS:-3}"
if [[ "${REQUIRE_FULL_GATE:-0}" == "1" ]]; then
  ITERS="${SOAK_ITERS:-20}"
fi

echo "Soak smoke: $ITERS iterations of Core+Documents filter"
for i in $(seq 1 "$ITERS"); do
  echo "== soak $i/$ITERS =="
  LOG="/tmp/soak-$i.log"
  set +e
  swift test --filter 'CodeEditorCoreTests|CodeEditorDocumentsTests' >"$LOG" 2>&1
  EC=$?
  set -e
  if [[ "$EC" -ne 0 ]]; then
    echo "FAIL: soak iteration $i (exit $EC)"
    tail -40 "$LOG"
    exit 1
  fi
  COUNT="$(rg -o 'Test run with [0-9]+ tests' "$LOG" | tail -1 | rg -o '[0-9]+' || echo 0)"
  if [[ "${COUNT:-0}" -lt 1 ]]; then
    echo "FAIL: soak iteration $i reported 0 tests"
    tail -20 "$LOG"
    exit 1
  fi
done
echo "OK:   soak smoke $ITERS iterations"
