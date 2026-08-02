#!/usr/bin/env bash
# QUAL-007 / §26.2 — inventory @unchecked Sendable; fail if new sites appear.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INV="$ROOT/Docs/Architecture/UNCHECKED-SENDABLE.md"
ALLOW="$ROOT/Baselines/unchecked-sendable-allowlist.txt"
mkdir -p Baselines

rg -n '@unchecked Sendable' Sources --glob '*.swift' | sort -u > Baselines/unchecked-sendable-current.txt || true
count="$(wc -l < Baselines/unchecked-sendable-current.txt | tr -d ' ')"

if [[ ! -f "$INV" ]]; then
  echo "FAIL: missing $INV — run scripts/generate-unchecked-sendable-inventory.sh"
  exit 1
fi

if [[ ! -f "$ALLOW" ]]; then
  cp Baselines/unchecked-sendable-current.txt "$ALLOW"
  echo "OK:   seeded allowlist ($count entries)"
  exit 0
fi

python3 - <<'PY'
from pathlib import Path
cur = {l.strip() for l in Path("Baselines/unchecked-sendable-current.txt").read_text().splitlines() if l.strip()}
allow = {l.strip() for l in Path("Baselines/unchecked-sendable-allowlist.txt").read_text().splitlines() if l.strip()}
added = sorted(cur - allow)
removed = sorted(allow - cur)
if added:
    print("FAIL: new @unchecked Sendable sites not in allowlist:")
    for a in added:
        print(" ", a)
    raise SystemExit(1)
print(f"OK:   unchecked Sendable within allowlist ({len(cur)} sites; {len(removed)} allowlist-only stale ok)")
PY
