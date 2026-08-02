#!/usr/bin/env bash
# Hard check: GHOSTTY.pin is well-formed; stamp matches pin when present.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/Docs/Architecture/GHOSTTY.pin"
[[ -f "$PIN" ]] || { echo "FAIL: missing $PIN"; exit 1; }
COMMIT="$(grep '^GHOSTTY_COMMIT=' "$PIN" | cut -d= -f2- | tr -d '[:space:]')"
REPO="$(grep '^GHOSTTY_REPO=' "$PIN" | cut -d= -f2- | tr -d '[:space:]')"
[[ -n "$COMMIT" && ${#COMMIT} -ge 7 ]] || { echo "FAIL: invalid GHOSTTY_COMMIT"; exit 1; }
[[ "$REPO" == https://* ]] || { echo "FAIL: invalid GHOSTTY_REPO"; exit 1; }
STAMP="$ROOT/Vendor/ghostty-build.stamp"
if [[ -f "$STAMP" ]]; then
  STAMP_COMMIT="$(head -1 "$STAMP" | tr -d '[:space:]')"
  if [[ "$STAMP_COMMIT" != "$COMMIT" ]]; then
    echo "FAIL: stamp commit $STAMP_COMMIT != pin $COMMIT"
    exit 1
  fi
  echo "OK: Ghostty stamp matches pin $COMMIT"
else
  echo "OK: Ghostty pin valid ($COMMIT); no build stamp (unlinked mode)"
fi
