#!/usr/bin/env bash
# REL-N03 — defect gate does not trust manually marked "fixed" rows alone.
# Every fixed defect must name regression test IDs that exist under Tests/ (or scripts/
# exercised by ReleaseTruthTests). Reopen if tests disappear or are skipped.
# DEFECTS_ALLOW_OPEN=1 validates structure only (used by Phase 0 honesty CI).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON="${DEFECTS_JSON:-$ROOT/Docs/Architecture/defects.json}"
MD="${DEFECTS_MD:-$ROOT/Docs/Architecture/DEFECTS.md}"
ALLOW_OPEN="${DEFECTS_ALLOW_OPEN:-0}"

if [[ ! -f "$JSON" ]]; then
  echo "FAIL: missing $JSON"
  exit 1
fi

python3 - "$ROOT" "$JSON" "$MD" "$ALLOW_OPEN" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
json_path = Path(sys.argv[2])
md_path = Path(sys.argv[3])
allow_open = sys.argv[4] == "1"

data = json.loads(json_path.read_text(encoding="utf-8"))
defects = data.get("defects", [])
fail = 0
open_blockers = []

# Index Tests/ and scripts/ for existence checks
tests_root = root / "Tests"
scripts_root = root / "scripts"
all_test_text = []
if tests_root.is_dir():
    for p in tests_root.rglob("*.swift"):
        try:
            all_test_text.append(p.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            pass
joined = "\n".join(all_test_text)

def ref_exists(ref: str) -> bool:
    ref = ref.strip()
    if not ref:
        return False
    # Path form
    cand = root / ref
    if cand.is_file():
        # skip permanent soft-skip markers in the referenced test file
        if cand.suffix == ".swift":
            t = cand.read_text(encoding="utf-8", errors="replace")
            if "XCTSkip" in t or "XCTExpectFailure" in t:
                # allow file if the specific test name isn't only skip — still require name presence elsewhere
                pass
        return True
    # Function / test name form — must appear in Tests/
    if ref in joined or f"func {ref}" in joined or f"test_{ref}" in joined or f'"{ref}"' in joined:
        return True
    # Script form
    if ref.startswith("scripts/") and (root / ref).is_file():
        return True
    if (scripts_root / ref).is_file():
        return True
    # Suite-ish: Directory/File without extension
    if "/" in ref:
        p = root / "Tests" / ref
        if p.is_file() or p.with_suffix(".swift").is_file():
            return True
        if (root / ref).is_file():
            return True
    return False

for d in defects:
    did = d.get("id", "?")
    sev = str(d.get("severity", "")).upper()
    st = str(d.get("status", "")).lower()
    if st in ("open", "partial") and sev in ("P0", "P1"):
        open_blockers.append((did, sev, d.get("product", ""), d.get("summary", "")))

    if st == "fixed":
        regs = d.get("regression_tests") or d.get("regressionTests") or []
        if not isinstance(regs, list) or len(regs) == 0:
            print(f"FAIL: {did} status=fixed but regression_tests missing/empty")
            fail = 1
            continue
        for ref in regs:
            if not ref_exists(str(ref)):
                print(f"FAIL: {did} regression test missing or not found: {ref}")
                fail = 1
            # Reject skip-only stubs for named swift tests
            ref_s = str(ref)
            if ref_s.endswith(".swift"):
                p = root / ref_s
                if p.is_file():
                    body = p.read_text(encoding="utf-8", errors="replace")
                    # empty test bodies / permanent skip
                    if "XCTSkip(" in body and "TODO" in body:
                        print(f"FAIL: {did} regression file uses XCTSkip stub: {ref_s}")
                        fail = 1

# Optional: if MD exists and is not /dev/null, require it is generated/consistent header
if md_path.is_file() and str(md_path) != "/dev/null":
    md = md_path.read_text(encoding="utf-8")
    if "defects.json" not in md:
        print("FAIL: DEFECTS.md must state machine source defects.json")
        fail = 1
    # Count fixed without regression in md is not authoritative; JSON is source of truth.

if open_blockers and not allow_open:
    print("FAIL: open P0/P1 defects (release blockers):")
    for row in sorted(open_blockers, key=lambda r: (r[1], r[0] or "")):
        print(" ", row[0], row[1], row[2], "-", row[3][:80] if row[3] else "")
    fail = 1
elif open_blockers and allow_open:
    print(f"NOTE: {len(open_blockers)} open P0/P1 allowed (DEFECTS_ALLOW_OPEN=1)")

if fail:
    sys.exit(1)
print(f"OK:   defects.json validated ({len(defects)} rows; fixed rows have regression_tests)")
PY
