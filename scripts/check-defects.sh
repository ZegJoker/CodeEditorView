#!/usr/bin/env bash
# Fail if DEFECTS.md has any open defect (any severity).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Docs/Architecture/DEFECTS.md"
if [[ ! -f "$FILE" ]]; then
  echo "FAIL: missing $FILE"
  exit 1
fi
python3 - "$FILE" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
open_rows = []
for line in text.splitlines():
    if not line.strip().startswith("|"):
        continue
    cols = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cols) < 4:
        continue
    if cols[0].lower() in ("id", "---") or set(cols[0]) <= set("- "):
        continue
    status = cols[3].lower()
    if status == "open":
        open_rows.append((cols[0], cols[1], cols[2]))
if open_rows:
    print("FAIL: open defects (zero residual policy):")
    for row in open_rows:
        print(" ", row)
    sys.exit(1)
print("OK:   no open defects in DEFECTS.md")
PY
