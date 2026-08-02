#!/usr/bin/env bash
# REL-N05 — performance gate requires real measurements; missing samples hard-fail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FILE="$ROOT/Docs/Architecture/PERF-BUDGETS.md"
BUDGETS_JSON="$ROOT/Baselines/performance/budgets.json"
SAMPLE="$ROOT/Baselines/evidence/perf-smoke.json"
fail=0

if [[ ! -f "$FILE" ]]; then
  echo "FAIL: missing $FILE"
  exit 1
fi

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
for key in "${required[@]}"; do
  if ! rg -qi "$key" "$FILE"; then
    echo "FAIL: PERF-BUDGETS.md missing budget topic: $key"
    fail=1
  fi
done

if ! rg -q 'P50' "$FILE" || ! rg -q 'P95' "$FILE"; then
  echo "FAIL: PERF-BUDGETS.md must define P50 and P95 columns"
  fail=1
fi
if ! rg -q 'P99' "$FILE"; then
  echo "FAIL: PERF-BUDGETS.md must define P99"
  fail=1
fi

if [[ ! -f "$BUDGETS_JSON" ]]; then
  echo "FAIL: missing machine budgets $BUDGETS_JSON"
  fail=1
else
  python3 - "$BUDGETS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
budgets = d.get("budgets") or d
need = ("p50", "p95", "p99")
# Accept either nested metrics with p50/p95/p99 or top-level policy keys
text = json.dumps(d).lower()
for k in need:
    if k not in text:
        print(f"FAIL: budgets.json missing {k}")
        raise SystemExit(1)
print("OK:   budgets.json has p50/p95/p99 policy fields")
PY
fi

if [[ ! -f "$SAMPLE" ]]; then
  echo "FAIL: missing required measurement sample $SAMPLE"
  fail=1
else
  python3 - "$SAMPLE" "$BUDGETS_JSON" <<'PY'
import json, sys
from pathlib import Path
sample_path, budgets_path = sys.argv[1], sys.argv[2]
d = json.load(open(sample_path, encoding="utf-8"))
if d.get("within_unit_bound") is not True:
    print("FAIL: perf-smoke.json within_unit_bound is not true")
    raise SystemExit(1)
# Require concrete measurement fields
has_measure = any(k in d for k in ("per_op_us", "total_ms", "p50_ms", "p95_ms", "p99_ms", "measurements"))
if not has_measure:
    print("FAIL: perf-smoke.json missing measurement fields")
    raise SystemExit(1)
# Prefer explicit percentiles when present
for k in ("p50_ms", "p95_ms", "p99_ms"):
    if k in d and not isinstance(d[k], (int, float)):
        print(f"FAIL: {k} must be numeric")
        raise SystemExit(1)
if Path(budgets_path).is_file():
    b = json.load(open(budgets_path, encoding="utf-8"))
    # Optional regression compare when sample names a metric budget key
    metric = d.get("metric")
    budgets = b.get("budgets") or {}
    if metric and metric in budgets and "total_ms" in d:
        # budgets may be scalar ms ceilings
        ceiling = budgets[metric]
        if isinstance(ceiling, (int, float)) and float(d["total_ms"]) > float(ceiling):
            print(f"FAIL: measurement {metric} total_ms={d['total_ms']} exceeds budget {ceiling}")
            raise SystemExit(1)
print("OK:   perf-smoke.json measured sample valid")
PY
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK:   performance budgets + measurements validated"
exit 0
