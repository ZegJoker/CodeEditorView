#!/usr/bin/env bash
# QUAL-003 — validate machine-generated release evidence JSON (hard).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="${1:-$ROOT/Baselines/evidence/release-evidence.json}"

if [[ ! -f "$EVIDENCE" ]]; then
  echo "FAIL: missing $EVIDENCE — run scripts/generate-release-evidence.sh first"
  exit 1
fi

python3 - "$EVIDENCE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
required = ["schema_version", "generated_at", "commit", "branch", "toolchain", "tests", "defects"]
missing = [k for k in required if k not in data]
if missing:
    print("FAIL: missing keys:", ", ".join(missing))
    sys.exit(1)
if int(data.get("schema_version", 0)) < 1:
    print("FAIL: schema_version must be >= 1")
    sys.exit(1)
tests = data["tests"]
if "exit_code" not in tests:
    print("FAIL: tests.exit_code missing")
    sys.exit(1)
if not isinstance(tests["exit_code"], int):
    print("FAIL: tests.exit_code must be int")
    sys.exit(1)
if tests["exit_code"] != 0:
    print(f"FAIL: tests.exit_code={tests['exit_code']} (must be 0)")
    sys.exit(1)
reported = int(tests.get("reported_tests") or 0)
if reported < 1:
    print("FAIL: tests.reported_tests must be >= 1")
    sys.exit(1)
open_blockers = int(data.get("defects", {}).get("open_p0_p1", -1))
if open_blockers < 0:
    print("FAIL: defects.open_p0_p1 missing")
    sys.exit(1)
if open_blockers != 0:
    print(f"FAIL: open_p0_p1={open_blockers} (must be 0)")
    sys.exit(1)
if not data.get("commit") or data["commit"] == "unknown":
    print("FAIL: commit unknown — evidence must bind to a git commit")
    sys.exit(1)
gates = data.get("gates") or {}
if gates.get("tests_passed") is not True:
    print("FAIL: gates.tests_passed must be true")
    sys.exit(1)
if gates.get("no_open_p0_p1") is not True:
    print("FAIL: gates.no_open_p0_p1 must be true")
    sys.exit(1)
if data.get("overall_pass") is not True:
    print("FAIL: overall_pass must be true")
    sys.exit(1)
print("OK:   release evidence valid", path)
print("      open_p0_p1=", open_blockers, "test_exit=", tests["exit_code"], "tests=", reported)
PY
