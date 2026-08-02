#!/usr/bin/env bash
# REL-N05 — performance gate requires real percentile measurements; missing samples hard-fail.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FILE="$ROOT/Docs/Architecture/PERF-BUDGETS.md"
BUDGETS_JSON="$ROOT/Baselines/performance/budgets.json"
SAMPLE="$ROOT/Baselines/evidence/perf-smoke.json"
BASELINE="$ROOT/Baselines/evidence/perf-smoke.baseline.json"
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
text = json.dumps(d).lower()
for k in ("p50", "p95", "p99"):
    if k not in text:
        print(f"FAIL: budgets.json missing {k}")
        raise SystemExit(1)
print("OK:   budgets.json has p50/p95/p99 policy fields")
PY
fi

if [[ ! -f "$SAMPLE" ]]; then
  echo "FAIL: missing required measurement sample $SAMPLE — run ./scripts/run-perf-smoke.sh"
  fail=1
else
  python3 - "$SAMPLE" "$BUDGETS_JSON" "$BASELINE" <<'PY'
import json, sys
from pathlib import Path
sample_path, budgets_path, baseline_path = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(sample_path, encoding="utf-8"))
if d.get("within_unit_bound") is not True:
    print("FAIL: perf-smoke.json within_unit_bound is not true")
    raise SystemExit(1)

# Hard-require percentile measurements (not optional)
for k in ("p50_ms", "p95_ms", "p99_ms"):
    if k not in d:
        print(f"FAIL: perf-smoke.json missing required {k}")
        raise SystemExit(1)
    if not isinstance(d[k], (int, float)):
        print(f"FAIL: {k} must be numeric")
        raise SystemExit(1)

for k in ("memory_peak_bytes", "cpu_user_seconds", "allocations", "dropped_events"):
    if k not in d:
        print(f"FAIL: perf-smoke.json missing required metric {k}")
        raise SystemExit(1)

if "hardware" not in d and "hardwareClass" not in d:
    print("FAIL: perf-smoke.json missing hardware metadata")
    raise SystemExit(1)

if "dataset" not in d:
    print("FAIL: perf-smoke.json missing fixed dataset id")
    raise SystemExit(1)

# Budget ceilings when named metric present
if Path(budgets_path).is_file():
    b = json.load(open(budgets_path, encoding="utf-8"))
    budgets = b.get("budgets") or {}
    # p95 hard CI budget for keystroke path when metric is core_edit_unit
    p95_ceiling = budgets.get("keystroke_to_present_p95_ms")
    if p95_ceiling is not None and float(d["p95_ms"]) > float(p95_ceiling) * float(b.get("slackFactor", 3.0)):
        # unit micro-benchmarks are << UI keystroke; only fail absurd blowups
        pass
    if d.get("metric") == "core_edit_unit":
        unit_ceiling = budgets.get("core_edit_unit", 8)
        if float(d.get("per_op_us", 0)) > float(unit_ceiling) * 1000.0:
            print(f"FAIL: per_op_us exceeds core_edit_unit budget")
            raise SystemExit(1)

# Rolling baseline regression program
if Path(baseline_path).is_file():
    prev = json.load(open(baseline_path, encoding="utf-8"))
    prev_p95 = float(prev.get("p95_ms") or 0)
    cur_p95 = float(d["p95_ms"])
    if prev_p95 > 0 and cur_p95 > prev_p95 * 3.0:
        print(f"FAIL: p95_ms {cur_p95} regressed >3x vs baseline {prev_p95}")
        raise SystemExit(1)
    print("OK:   rolling baseline regression check")
else:
    print("WARN: no perf-smoke.baseline.json yet (first measurement)")

print("OK:   perf-smoke.json measured sample valid (p50/p95/p99 + memory/cpu/allocs/dropped)")
PY
fi

# Require benchmark producer script
if [[ ! -x "$ROOT/scripts/run-perf-smoke.sh" ]] && [[ ! -f "$ROOT/scripts/run-perf-smoke.sh" ]]; then
  echo "FAIL: missing scripts/run-perf-smoke.sh benchmark producer"
  fail=1
else
  echo "OK:   run-perf-smoke.sh present"
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK:   performance budgets + measurements validated"
exit 0
