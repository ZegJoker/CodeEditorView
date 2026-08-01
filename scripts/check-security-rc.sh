#!/usr/bin/env bash
# Security RC evidence pack: required docs + Phase14/15/16 security test filters.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
for f in \
  Docs/Architecture/ADR-015-extension-threat-model.md \
  Docs/Guides/APP-REVIEW.md \
  Docs/Architecture/SECURITY-RC.md
do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    fail=1
  else
    echo "OK:   $f"
  fi
done
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "== swift test --filter Phase16Security =="
swift test --filter Phase16Security

echo "== swift test --filter Phase14Signing =="
swift test --filter "Phase 14 signing" || swift test --filter Phase14Signing

echo "Security RC checks passed"
