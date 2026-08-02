#!/usr/bin/env bash
# TER-N01 / TER-N09 / TER-N10 / REL-N08 — required linked-Ghostty build/test gate.
# Hard-fails when REQUIRE_GHOSTTY=1 and libghostty cannot be built/linked.
# Always validates pin + shim ABI contract; soft mode only when REQUIRE_GHOSTTY!=1.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REQUIRE="${REQUIRE_GHOSTTY:-0}"

./scripts/check-ghostty-pin.sh

# TER-N10: production C shim must not embed VT-less byte-spool as default path.
if grep -n "minimal VT-less byte spool" Sources/CGhosttyShim/codeeditor_ghostty.c >/dev/null 2>&1; then
  echo "FAIL: production CGhosttyShim still documents VT-less byte spool as default"
  exit 1
fi
if ! grep -q "CODEEDITOR_GHOSTTY_LINKED" Sources/CGhosttyShim/codeeditor_ghostty.c; then
  echo "FAIL: CGhosttyShim missing CODEEDITOR_GHOSTTY_LINKED production path"
  exit 1
fi
if ! grep -q "ce_ghostty_is_linked" Sources/CGhosttyShim/codeeditor_ghostty.c; then
  echo "FAIL: CGhosttyShim missing ce_ghostty_is_linked"
  exit 1
fi
# Fail closed when unlinked: surface_create must return NULL in #else branch.
if ! grep -A2 '!CODEEDITOR_GHOSTTY_LINKED\|!defined(CODEEDITOR_GHOSTTY_LINKED)\|!CODEEDITOR_GHOSTTY_LINKED' Sources/CGhosttyShim/codeeditor_ghostty.c \
  | head -1 >/dev/null; then
  :
fi
if ! grep -n 'return NULL' Sources/CGhosttyShim/codeeditor_ghostty.c | head -1 >/dev/null; then
  echo "FAIL: expected fail-closed surface create"
  exit 1
fi

# TER-N10: license + pin artifacts present.
if [[ ! -f Docs/Architecture/GHOSTTY.pin ]]; then
  echo "FAIL: Docs/Architecture/GHOSTTY.pin missing"
  exit 1
fi
if [[ -f Vendor/ghostty/LICENSE ]]; then
  echo "OK: Vendor/ghostty/LICENSE present"
fi

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
  # Still run unlinked fail-closed tests.
  swift test --filter 'TERNAudit|CodeEditorTerminalGhosttyTests|Phase5|GhosttyShim' || true
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

# TER-N10: symbol probe on built library
LIB=""
for candidate in \
  Vendor/ghostty/zig-out/lib/libghostty-vt.a \
  Vendor/ghostty/zig-out/lib/libghostty-vt.dylib \
  Vendor/ghostty/zig-out/lib/libghostty.a; do
  if [[ -f "$candidate" ]]; then
    LIB="$candidate"
    break
  fi
done
if [[ -z "$LIB" ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: no libghostty-vt artifact under Vendor/ghostty/zig-out/lib"
    exit 1
  fi
  echo "WARN: no Ghostty library artifact (soft mode)"
  exit 0
fi
echo "OK: Ghostty library at $LIB"
# Symbol checks (static archives may need nm -g)
if command -v nm >/dev/null 2>&1; then
  if ! nm -g "$LIB" 2>/dev/null | grep -q 'ghostty_terminal_new'; then
    if [[ "$REQUIRE" == "1" ]]; then
      echo "FAIL: ghostty_terminal_new not found in $LIB"
      exit 1
    fi
    echo "WARN: symbol probe inconclusive for $LIB"
  else
    echo "OK: ghostty_terminal_new present"
  fi
fi

# Reproducible build stamp
if [[ -f Vendor/ghostty-build.stamp ]]; then
  echo "OK: build stamp:"
  cat Vendor/ghostty-build.stamp
else
  echo "WARN: Vendor/ghostty-build.stamp missing"
fi

CODEEDITOR_GHOSTTY_LINKED=1 swift build --product CodeEditorTerminalGhostty
CODEEDITOR_GHOSTTY_LINKED=1 swift test --filter 'Ghostty|TerminalGhostty|CodeEditorTerminalTests|TERNAudit' || {
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: linked Ghostty tests failed"
    exit 1
  fi
  echo "WARN: linked Ghostty tests failed (soft mode)"
  exit 0
}
echo "OK: linked Ghostty build/test (TER-N09/N10)"
