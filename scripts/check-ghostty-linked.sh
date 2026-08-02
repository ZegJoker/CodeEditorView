#!/usr/bin/env bash
# REL-N08 — required linked-Ghostty build/test gate for release paths.
# Hard-fails when REQUIRE_GHOSTTY=1 and libghostty cannot be built/linked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REQUIRE="${REQUIRE_GHOSTTY:-0}"

./scripts/check-ghostty-pin.sh

if [[ ! -d Vendor/ghostty ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_GHOSTTY=1 but Vendor/ghostty missing"
    exit 1
  fi
  echo "OK: Ghostty pin valid; vendor tree absent (soft mode)"
  exit 0
fi

chmod +x scripts/build-ghostty.sh scripts/link-ghostty-flags.sh
if ! ./scripts/build-ghostty.sh vt; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: Ghostty vt build failed (REQUIRE_GHOSTTY=1)"
    exit 1
  fi
  echo "WARN: Ghostty build failed (soft mode)"
  exit 0
fi

# shellcheck disable=SC1090
eval "$(./scripts/link-ghostty-flags.sh)"
if [[ "${CODEEDITOR_GHOSTTY_LINKED:-}" != "1" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: Ghostty built but link flags did not set CODEEDITOR_GHOSTTY_LINKED=1"
    exit 1
  fi
  echo "WARN: Ghostty not linked (soft mode)"
  exit 0
fi

CODEEDITOR_GHOSTTY_LINKED=1 swift build --product CodeEditorTerminalGhostty
CODEEDITOR_GHOSTTY_LINKED=1 swift test --filter 'Ghostty|TerminalGhostty|CodeEditorTerminalTests' || {
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: linked Ghostty tests failed"
    exit 1
  fi
  echo "WARN: linked Ghostty tests failed (soft mode)"
  exit 0
}
echo "OK: linked Ghostty build/test"
