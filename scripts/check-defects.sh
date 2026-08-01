#!/usr/bin/env bash
# Fail if DEFECTS.md has any open P0 or P1 defect (release blockers).
# P2/P3 open defects are allowed during pre-alpha remediation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Docs/Architecture/DEFECTS.md"
JSON="$ROOT/Docs/Architecture/defects.json"
if [[ ! -f "$FILE" ]]; then
  echo "FAIL: missing $FILE"
  exit 1
fi
python3 - "$FILE" "$JSON" <<'PY'
import re, sys, json
from pathlib import Path

md_path, json_path = sys.argv[1], sys.argv[2]
text = open(md_path, encoding="utf-8").read()
open_blockers = []
for line in text.splitlines():
    if not line.strip().startswith("|"):
        continue
    cols = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cols) < 4:
        continue
    if cols[0].lower() in ("id", "---") or set(cols[0]) <= set("- "):
        continue
    severity = cols[1].upper()
    status = cols[3].lower()
    if status in ("open", "partial") and severity in ("P0", "P1"):
        open_blockers.append((cols[0], severity, cols[2]))

if Path(json_path).is_file():
    data = json.loads(Path(json_path).read_text(encoding="utf-8"))
    for d in data.get("defects", []):
        sev = str(d.get("severity", "")).upper()
        st = str(d.get("status", "")).lower()
        if st in ("open", "partial") and sev in ("P0", "P1"):
            key = (d.get("id"), sev, d.get("product", ""))
            if not any(r[0] == key[0] for r in open_blockers):
                open_blockers.append(key)

if open_blockers:
    print("FAIL: open P0/P1 defects (release blockers):")
    for row in sorted(set(open_blockers), key=lambda r: (r[1], r[0] or "")):
        print(" ", row)
    print("NOTE: pre-alpha remediation expects this to fail until all P0/P1 are closed.")
    sys.exit(1)
print("OK:   no open P0/P1 defects in DEFECTS.md / defects.json")
PY
