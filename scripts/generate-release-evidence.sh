#!/usr/bin/env bash
# CI-001: generate machine-readable release evidence from executable job results.
# This script is a *producer* of status — never a consumer of hand-authored pass tables.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$ROOT/Baselines/evidence}"
mkdir -p "$OUT_DIR"

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
SWIFT_VER="$(swift --version 2>&1 | head -1 | tr -d '\n' || echo unknown)"
XCODE_VER="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo unknown)"
DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Run targeted product tests and capture totals when possible.
TEST_LOG="$OUT_DIR/swift-test.log"
set +e
(
  cd "$ROOT"
  swift test --filter 'CodeEditorCoreTests|CodeEditorDocumentsTests|CodeEditorWorkspaceTests|CodeEditorCommandsTests|CodeEditorTerminalTests' 2>&1
) | tee "$TEST_LOG"
TEST_EC=${PIPESTATUS[0]}
set -e

PASSED="$(rg -o 'Test run with [0-9]+ tests' "$TEST_LOG" | tail -1 | rg -o '[0-9]+' || echo 0)"
SUITES="$(rg -o '[0-9]+ suites' "$TEST_LOG" | tail -1 | rg -o '^[0-9]+' || echo 0)"

# Defect open P0/P1 count from defects.json
DEFECTS_JSON="$ROOT/Docs/Architecture/defects.json"
OPEN_BLOCKERS=0
if [[ -f "$DEFECTS_JSON" ]]; then
  OPEN_BLOCKERS="$(python3 - "$DEFECTS_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for x in d.get("defects",[]) if str(x.get("severity","")).upper() in ("P0","P1") and str(x.get("status","")).lower() in ("open","partial")))
PY
)"
fi

EVIDENCE="$OUT_DIR/release-evidence.json"
python3 - "$EVIDENCE" <<PY
import json, sys
ev = {
  "schema_version": 1,
  "generated_at": "$DATE_UTC",
  "commit": "$COMMIT",
  "branch": "$BRANCH",
  "toolchain": {
    "swift": """$SWIFT_VER""",
    "xcode": """$XCODE_VER""",
  },
  "tests": {
    "exit_code": $TEST_EC,
    "reported_tests": int("$PASSED" or 0),
    "reported_suites": int("$SUITES" or 0),
    "log": "Baselines/evidence/swift-test.log",
  },
  "defects": {
    "open_p0_p1": int("$OPEN_BLOCKERS"),
    "source": "Docs/Architecture/defects.json",
  },
  "gates": {
    "tests_passed": $TEST_EC == 0,
    "no_open_p0_p1": int("$OPEN_BLOCKERS") == 0,
  },
  "overall_pass": ($TEST_EC == 0) and (int("$OPEN_BLOCKERS") == 0),
}
json.dump(ev, open(sys.argv[1], "w"), indent=2)
print("wrote", sys.argv[1])
print(json.dumps(ev["gates"], indent=2))
PY

# Generate scorecard residual hints from open defects (evidence → docs, not reverse).
SCORE_OUT="$OUT_DIR/scorecard-residuals.json"
python3 - "$DEFECTS_JSON" "$SCORE_OUT" <<'PY'
import json,sys
from collections import defaultdict
d=json.load(open(sys.argv[1]))
by=defaultdict(list)
for x in d.get("defects",[]):
    if str(x.get("status","")).lower() in ("open","partial") and str(x.get("severity","")).upper() in ("P0","P1"):
        by[x.get("product","unknown")].append(x["id"])
json.dump({"residuals_by_product": by}, open(sys.argv[2],"w"), indent=2)
print("wrote", sys.argv[2])
PY

if [[ "$TEST_EC" -ne 0 ]]; then
  echo "FAIL: test suite exit $TEST_EC"
  exit "$TEST_EC"
fi
echo "OK: release evidence generated (open P0/P1=$OPEN_BLOCKERS)"
