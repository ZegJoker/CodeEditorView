#!/usr/bin/env bash
# QUAL-006 / §26.7 — performance budgets documented + machine sample when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Docs/Architecture/PERF-BUDGETS.md"

if [[ ! -f "$FILE" ]]; then
  echo "FAIL: missing $FILE"
  exit 1
fi

# Require named budget keys from the audit §26.7 list.
required=(
  "keystroke"
  "memory"
  "scroll"
  "parse"
  "workspace"
  "search"
  "LSP"
  "terminal"
  "extension"
  "first visible"
)
fail=0
for key in "${required[@]}"; do
  if ! rg -qi "$key" "$FILE"; then
    echo "FAIL: PERF-BUDGETS.md missing budget topic: $key"
    fail=1
  fi
done

# Must include P50/P95 numeric policy language.
if ! rg -q 'P50' "$FILE" || ! rg -q 'P95' "$FILE"; then
  echo "FAIL: PERF-BUDGETS.md must define P50 and P95 columns"
  fail=1
fi

# If a measured sample exists, require within_unit_bound true.
SAMPLE="$ROOT/Baselines/evidence/perf-smoke.json"
if [[ -f "$SAMPLE" ]]; then
  python3 - "$SAMPLE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if d.get("within_unit_bound") is not True:
    print("FAIL: perf-smoke.json within_unit_bound is not true")
    raise SystemExit(1)
if "per_op_us" not in d and "total_ms" not in d:
    print("FAIL: perf-smoke.json missing measurement fields")
    raise SystemExit(1)
print("OK:   perf-smoke.json measured sample valid")
PY
else
  echo "NOTE: Baselines/evidence/perf-smoke.json not yet present (produced by Phase11PerfSmokeTests)"
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK:   PERF-BUDGETS.md present with required topics"
exit 0
