#!/usr/bin/env bash
# REL-N05 — fixed-dataset editor benchmarks (DocumentStore / LineIndex), not synthetic Python work.
# Produces Baselines/evidence/perf-smoke.json with p50/p95/p99, memory, CPU, allocations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${1:-$ROOT/Baselines/evidence}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/perf-smoke.json"
BASELINE="$OUT_DIR/perf-smoke.baseline.json"

export PERF_SMOKE_EMIT=1
export PERF_SMOKE_OUT="$OUT"
export PERF_ITERATIONS="${PERF_ITERATIONS:-80}"
export PERF_WARMUP="${PERF_WARMUP:-8}"
export PERF_DATASET="${PERF_DATASET:-editor_fixed_v1}"

echo "== REL-N05 fixed-dataset editor benchmarks (swift test) =="
# Prefer --skip-build when package already built (avoids SwiftPM lock deadlocks under nested tests).
PERF_FILTER="test_REL_N05_fixedDatasetEditorBenchmarks"
if [[ -d "$ROOT/.build" ]] && [[ "${PERF_FORCE_BUILD:-0}" != "1" ]]; then
  SWTEST=(swift test --skip-build --filter "$PERF_FILTER")
else
  SWTEST=(swift test --filter "$PERF_FILTER")
fi
if ! "${SWTEST[@]}" 2>&1 | tee /tmp/perf-smoke-swift.log | tail -30; then
  # Retry once with full build if skip-build missed the suite
  if [[ "${PERF_FORCE_BUILD:-0}" != "1" ]]; then
    echo "WARN: skip-build path failed; retrying with build" >&2
    if ! swift test --filter "$PERF_FILTER" 2>&1 | tee /tmp/perf-smoke-swift.log | tail -30; then
      echo "FAIL: editor fixed-dataset benchmarks failed" >&2
      exit 1
    fi
  else
    echo "FAIL: editor fixed-dataset benchmarks failed" >&2
    exit 1
  fi
fi

if [[ ! -f "$OUT" ]]; then
  echo "FAIL: benchmark did not write $OUT" >&2
  exit 1
fi

# Validate shape (must be editor fixed dataset, not python microbench)
python3 - "$OUT" "$BASELINE" <<'PY'
import json, sys
from pathlib import Path
out_path, baseline_path = sys.argv[1], sys.argv[2]
d = json.load(open(out_path, encoding="utf-8"))
required = [
    "p50_ms", "p95_ms", "p99_ms", "memory_peak_bytes", "cpu_user_seconds",
    "allocations", "dropped_events", "dataset", "hardware", "within_unit_bound",
    "producer", "metrics",
]
for k in required:
    if k not in d:
        print(f"FAIL: missing {k}", file=sys.stderr)
        raise SystemExit(1)
if d.get("dataset") != "editor_fixed_v1" and not str(d.get("dataset", "")).startswith("editor_"):
    print("FAIL: dataset must be editor fixed corpus, not synthetic microbench", file=sys.stderr)
    raise SystemExit(1)
if "python" in str(d.get("producer", "")).lower() and "RELN05" not in str(d.get("producer", "")):
    print("FAIL: producer must be Swift fixed-dataset benchmarks", file=sys.stderr)
    raise SystemExit(1)
metrics = d.get("metrics") or []
names = {m.get("name") for m in metrics if isinstance(m, dict)}
for need in ("keystroke_insert", "line_index_rebuild", "document_parse_load"):
    if need not in names:
        print(f"FAIL: metrics missing {need}", file=sys.stderr)
        raise SystemExit(1)
if d.get("within_unit_bound") is not True:
    print("FAIL: within_unit_bound is not true", file=sys.stderr)
    raise SystemExit(1)
# Rolling baseline — rewrite when producer/dataset changes; only fail large regressions on same producer
if Path(baseline_path).is_file():
    prev = json.load(open(baseline_path, encoding="utf-8"))
    same_producer = prev.get("producer") == d.get("producer") and prev.get("dataset") == d.get("dataset")
    prev_p95 = float(prev.get("p95_ms") or 0)
    cur_p95 = float(d["p95_ms"])
    if same_producer and prev_p95 > 0 and cur_p95 > max(prev_p95 * 10.0, 5.0):
        # absolute floor 5ms avoids microsecond noise false fails on keystroke microbenches
        print(f"FAIL: p95 regression {cur_p95} vs baseline {prev_p95}", file=sys.stderr)
        raise SystemExit(1)
# Always refresh rolling baseline sample for next compare (committed by CI when green)
Path(baseline_path).write_text(json.dumps(d, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"OK: wrote {out_path} dataset={d['dataset']} p50={d['p50_ms']:.4f} p95={d['p95_ms']:.4f} p99={d['p99_ms']:.4f}")
PY
