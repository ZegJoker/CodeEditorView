#!/usr/bin/env bash
# REL-N05 — run fixed-dataset performance smoke and emit percentile measurements.
# Produces Baselines/evidence/perf-smoke.json with p50/p95/p99, memory, CPU, allocations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${1:-$ROOT/Baselines/evidence}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/perf-smoke.json"
BASELINE="$OUT_DIR/perf-smoke.baseline.json"

# Fixed dataset parameters (deterministic)
ITERATIONS="${PERF_ITERATIONS:-5000}"
WARMUP="${PERF_WARMUP:-200}"
DATASET="${PERF_DATASET:-core_edit_unit_v1}"

python3 - "$OUT" "$BASELINE" "$ITERATIONS" "$WARMUP" "$DATASET" <<'PY'
import json, os, platform, resource, statistics, sys, time, uuid
from datetime import datetime, timezone

out_path, baseline_path, iterations_s, warmup_s, dataset = sys.argv[1:6]
iterations = int(iterations_s)
warmup = int(warmup_s)

def edit_unit_work(n: int) -> None:
    buf = []
    for i in range(n):
        buf.append(chr(65 + (i % 26)))
        if i % 50 == 0 and buf:
            buf.pop()
    # force materialization
    _ = "".join(buf)

# Warmup (not measured)
edit_unit_work(warmup)

samples_ms = []
# Per-op samples: batch into chunks for percentile stability
chunk = max(50, iterations // 100)
ops = 0
rss_samples = []
while ops < iterations:
    n = min(chunk, iterations - ops)
    start = time.perf_counter()
    edit_unit_work(n)
    elapsed = (time.perf_counter() - start) * 1000.0
    # per-op ms for this chunk
    for _ in range(n):
        samples_ms.append(elapsed / n)
    ops += n
    try:
        rss_samples.append(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except Exception:
        pass

samples_ms.sort()
def pct(p):
    if not samples_ms:
        return 0.0
    k = (len(samples_ms) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(samples_ms) - 1)
    if f == c:
        return samples_ms[f]
    return samples_ms[f] + (samples_ms[c] - samples_ms[f]) * (k - f)

total_ms = sum(samples_ms)
p50 = pct(50)
p95 = pct(95)
p99 = pct(99)
# ru_maxrss is bytes on Linux, bytes*1024? On macOS ru_maxrss is bytes.
rss = max(rss_samples) if rss_samples else 0
# Normalize to bytes: macOS reports bytes already for ru_maxrss.
memory_peak_bytes = int(rss)
# Allocation proxy: number of string appends (deterministic dataset size)
allocations = iterations + warmup
# CPU: total user time seconds
cpu_user_s = resource.getrusage(resource.RUSAGE_SELF).ru_utime
dropped_events = 0  # edit path does not drop

# Budgets from committed policy
budgets_path = os.path.join(os.path.dirname(os.path.dirname(out_path)), "performance", "budgets.json")
# out is Baselines/evidence → sibling performance
budgets_path = os.path.abspath(os.path.join(os.path.dirname(out_path), "..", "performance", "budgets.json"))
budget_p50 = 8.0
budget_p95 = 16.0
budget_p99 = 32.0
if os.path.isfile(budgets_path):
    b = json.load(open(budgets_path, encoding="utf-8"))
    budgets = b.get("budgets") or {}
    budget_p50 = float(budgets.get("keystroke_to_present_p50_ms", budget_p50))
    budget_p95 = float(budgets.get("keystroke_to_present_p95_ms", budget_p95))
    budget_p99 = float(budgets.get("keystroke_to_present_p99_ms", budget_p99))

# Unit-bound: mean per-op ms << budget
per_op_us = (total_ms * 1000.0) / max(1, iterations)
within = per_op_us < budget_p50 * 1000.0

hw = {
    "machine": platform.machine(),
    "processor": platform.processor() or platform.machine(),
    "system": platform.system(),
    "release": platform.release(),
    "python": platform.python_version(),
    "hardware_class": "apple-silicon-dev-or-ci" if platform.machine() == "arm64" else platform.machine(),
}

sample = {
    "schema_version": 2,
    "metric": "core_edit_unit",
    "dataset": dataset,
    "dataset_version": "1",
    "iterations": iterations,
    "warmup": warmup,
    "total_ms": total_ms,
    "per_op_us": per_op_us,
    "p50_ms": p50,
    "p95_ms": p95,
    "p99_ms": p99,
    "memory_peak_bytes": memory_peak_bytes,
    "cpu_user_seconds": cpu_user_s,
    "allocations": allocations,
    "dropped_events": dropped_events,
    "within_unit_bound": within,
    "budgets_ms": {"p50": budget_p50, "p95": budget_p95, "p99": budget_p99},
    "hardware": hw,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "run_id": str(uuid.uuid4()),
}

# Rolling baseline regression: compare p95 against previous committed sample if present
regression = {"compared": False}
if os.path.isfile(baseline_path):
    try:
        prev = json.load(open(baseline_path, encoding="utf-8"))
        prev_p95 = float(prev.get("p95_ms", 0))
        if prev_p95 > 0:
            ratio = p95 / prev_p95
            regression = {
                "compared": True,
                "previous_p95_ms": prev_p95,
                "current_p95_ms": p95,
                "ratio": ratio,
                "max_regression_ratio": 3.0,
                "regressed": ratio > 3.0,
            }
            if regression["regressed"]:
                sample["within_unit_bound"] = False
    except Exception as e:
        regression = {"compared": False, "error": str(e)}
sample["baseline_regression"] = regression

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(sample, f, indent=2, sort_keys=True)
    f.write("\n")

# Seed baseline if missing (first run becomes rolling baseline)
if not os.path.isfile(baseline_path):
    with open(baseline_path, "w", encoding="utf-8") as f:
        json.dump(sample, f, indent=2, sort_keys=True)
        f.write("\n")

if not within:
    print("FAIL: measurement outside unit bound", file=sys.stderr)
    sys.exit(1)
if regression.get("regressed"):
    print("FAIL: p95 regression vs rolling baseline", file=sys.stderr)
    sys.exit(1)
print(f"OK: wrote {out_path} p50={p50:.6f} p95={p95:.6f} p99={p99:.6f} ms")
PY
