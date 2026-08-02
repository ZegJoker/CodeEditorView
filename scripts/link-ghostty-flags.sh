#!/usr/bin/env bash
# Emit swiftc/clang link flags when a Ghostty build stamp is present.
# Usage: eval "$(./scripts/link-ghostty-flags.sh)"  or  ./scripts/link-ghostty-flags.sh --print
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$ROOT/Vendor/ghostty-build.stamp"
OUT="$ROOT/Vendor/ghostty/zig-out"
INC="$ROOT/Vendor/ghostty/include"

if [[ ! -f "$STAMP" || ! -d "$OUT" ]]; then
  if [[ "${1:-}" == "--require" ]]; then
    echo "FAIL: Ghostty not built. Run ./scripts/build-ghostty.sh" >&2
    exit 1
  fi
  echo "# Ghostty not linked (shim-only mode)"
  exit 0
fi

LIBDIR="$OUT/lib"
if [[ ! -d "$LIBDIR" ]]; then
  # Some Ghostty layouts install libs at zig-out root
  LIBDIR="$OUT"
fi

# Prefer libghostty-vt for state engine; fall back to ghostty-internal / libghostty names.
LIBNAME=""
for cand in ghostty-vt libghostty-vt ghostty-internal ghostty; do
  if ls "$LIBDIR"/*"${cand}"* >/dev/null 2>&1; then
    LIBNAME="$cand"
    break
  fi
done

echo "export CODEEDITOR_GHOSTTY_LINKED=1"
echo "export CODEEDITOR_GHOSTTY_CFLAGS=\"-ICODEEDITOR_PLACEHOLDER -DCODEEDITOR_GHOSTTY_LINKED=1\"" | sed "s|CODEEDITOR_PLACEHOLDER|$INC|"
if [[ -n "$LIBNAME" ]]; then
  # strip lib prefix for -l
  LFLAG="${LIBNAME#lib}"
  echo "export CODEEDITOR_GHOSTTY_LDFLAGS=\"-L$LIBDIR -l$LFLAG\""
else
  echo "export CODEEDITOR_GHOSTTY_LDFLAGS=\"-L$LIBDIR\""
fi
echo "# Ghostty linked from $LIBDIR (see $STAMP)"
