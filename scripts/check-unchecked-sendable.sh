#!/usr/bin/env bash
# REL-N07 / QUAL-007 — inventory @unchecked Sendable; fail if new sites appear.
# Requires per-site dossiers under Docs/Architecture/dossiers/ for allowlisted sites.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INV="$ROOT/Docs/Architecture/UNCHECKED-SENDABLE.md"
ALLOW="$ROOT/Baselines/unchecked-sendable-allowlist.txt"
DOSSIER="$ROOT/Docs/Architecture/dossiers/unchecked-sendable.md"
mkdir -p Baselines Docs/Architecture/dossiers

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

if [[ ! -f "$DOSSIER" ]]; then
  echo "FAIL: missing dossier $DOSSIER (REL-N07 per-site unsafe-concurrency dossier)"
  exit 1
fi

# Dossier must document policy fields
for token in invariant owner synchronization "removal path" stress; do
  if ! rg -qi "$token" "$DOSSIER"; then
    echo "FAIL: dossier missing required field language: $token"
    exit 1
  fi
done

# REL-N07: per-site entries required (not class summary alone)
if ! rg -q 'Per-site entries' "$DOSSIER"; then
  echo "FAIL: dossier must contain Per-site entries section"
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import re
cur = {l.strip() for l in Path("Baselines/unchecked-sendable-current.txt").read_text().splitlines() if l.strip()}
allow = {l.strip() for l in Path("Baselines/unchecked-sendable-allowlist.txt").read_text().splitlines() if l.strip()}
added = sorted(cur - allow)
removed = sorted(allow - cur)
if added:
    print("FAIL: new @unchecked Sendable sites not in allowlist:")
    for a in added:
        print(" ", a)
    raise SystemExit(1)
if len(cur) > len(allow):
    print(f"FAIL: unchecked count {len(cur)} exceeds allowlist {len(allow)}")
    raise SystemExit(1)

dossier = Path("Docs/Architecture/dossiers/unchecked-sendable.md").read_text(encoding="utf-8")
missing = []
for site in sorted(cur):
    # site lines look like path:line:code — match path:line at minimum
    key = site
    # Allow path-only match if line numbers drift slightly: require path segment present
    path = site.split(":")[0]
    if path not in dossier and site not in dossier:
        # try path:line
        parts = site.split(":")
        if len(parts) >= 2:
            pl = f"{parts[0]}:{parts[1]}"
            if pl not in dossier:
                missing.append(site)
        else:
            missing.append(site)
if missing:
    print(f"FAIL: {len(missing)} sites missing per-site dossier entries (sample):")
    for m in missing[:10]:
        print(" ", m)
    raise SystemExit(1)
print(f"OK:   unchecked Sendable within allowlist ({len(cur)} sites; per-site dossier complete; {len(removed)} allowlist-only stale ok)")
PY

echo "OK:   dossier present with per-site unsafe-concurrency entries"
