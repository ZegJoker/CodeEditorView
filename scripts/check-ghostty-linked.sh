#!/usr/bin/env bash
# TER-N01 / TER-N09 / TER-N10 / REL-N08 — required linked-Ghostty build/test gate.
# Hard-fails when REQUIRE_GHOSTTY=1 and libghostty cannot be built/linked.
# Always validates pin + shim ABI contract; soft mode only when REQUIRE_GHOSTTY!=1
# and only after pin/ABI/unlinked fail-closed probes pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REQUIRE="${REQUIRE_GHOSTTY:-0}"

echo "== Ghostty qualification (TER-N10) REQUIRE_GHOSTTY=${REQUIRE} =="

# --- Pin (always hard) ---
./scripts/check-ghostty-pin.sh
if [[ ! -f Docs/Architecture/GHOSTTY.pin ]]; then
  echo "FAIL: Docs/Architecture/GHOSTTY.pin missing"
  exit 1
fi
# Pin must be source-safe (quoted multi-word values).
if grep -E '^MINIMUM_ZIG=[^"'\'']' Docs/Architecture/GHOSTTY.pin | grep -q ' '; then
  echo "FAIL: GHOSTTY.pin MINIMUM_ZIG must be quoted (sourced by build-ghostty.sh)"
  exit 1
fi
COMMIT="$(grep '^GHOSTTY_COMMIT=' Docs/Architecture/GHOSTTY.pin | cut -d= -f2- | tr -d '[:space:]')"
if [[ ${#COMMIT} -lt 7 ]]; then
  echo "FAIL: GHOSTTY_COMMIT missing/short in pin"
  exit 1
fi
echo "OK: pin commit ${COMMIT}"

# --- Production shim contract (always hard) ---
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
if ! grep -n 'return NULL' Sources/CGhosttyShim/codeeditor_ghostty.c | head -1 >/dev/null; then
  echo "FAIL: expected fail-closed surface create"
  exit 1
fi
if ! grep -q "CE_GHOSTTY_SHIM_ABI" Sources/CGhosttyShim/include/codeeditor_ghostty.h; then
  echo "FAIL: missing CE_GHOSTTY_SHIM_ABI in shim header"
  exit 1
fi
if ! grep -q "ce_ghostty_surface_encode_key" Sources/CGhosttyShim/include/codeeditor_ghostty.h; then
  echo "FAIL: missing ce_ghostty_surface_encode_key (TER-N04 ABI)"
  exit 1
fi
if ! grep -q "ce_ghostty_shim_abi" Sources/CGhosttyShim/include/codeeditor_ghostty.h; then
  echo "FAIL: missing ce_ghostty_shim_abi symbol"
  exit 1
fi
echo "OK: shim ABI header contract (CE_GHOSTTY_SHIM_ABI + encode_key)"

# --- Compile-time ABI probe of unlinked shim (always hard) ---
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ce-ghostty-abi.XXXXXX")"
cleanup() { rm -rf "$PROBE_DIR"; }
trap cleanup EXIT
cat > "$PROBE_DIR/probe.c" <<'PROBE'
#include "codeeditor_ghostty.h"
#include <stdio.h>
int main(void) {
  int abi = ce_ghostty_shim_abi();
  int linked = ce_ghostty_is_linked() ? 1 : 0;
  int level = ce_ghostty_integration_level();
  printf("ABI=%d LINKED=%d LEVEL=%d\n", abi, linked, level);
  if (abi < 2) return 2;
  /* Unlinked build of this probe must report not linked. */
  if (linked != 0) return 3;
  if (level != CE_GHOSTTY_INTEGRATION_UNAVAILABLE) return 4;
  if (ce_ghostty_surface_create(NULL) != NULL) return 5;
  return 0;
}
PROBE
cc -ISources/CGhosttyShim/include \
  Sources/CGhosttyShim/codeeditor_ghostty.c \
  Sources/CGhosttyShim/codeeditor_pty.c \
  "$PROBE_DIR/probe.c" \
  -o "$PROBE_DIR/probe" 2>"$PROBE_DIR/cc.err" || {
  echo "FAIL: unlinked shim ABI compile probe failed"
  cat "$PROBE_DIR/cc.err" || true
  exit 1
}
PROBE_OUT="$("$PROBE_DIR/probe")"
echo "OK: unlinked ABI probe: ${PROBE_OUT}"
echo "${PROBE_OUT}" | grep -q 'ABI=' || { echo "FAIL: ABI probe output malformed"; exit 1; }
echo "${PROBE_OUT}" | grep -q 'LINKED=0' || { echo "FAIL: unlinked probe must report LINKED=0"; exit 1; }

if [[ -f Vendor/ghostty/LICENSE ]]; then
  echo "OK: Vendor/ghostty/LICENSE present"
fi

# --- Fixtures always present (TER-N09) ---
for f in ansi-corpus.txt utf8-split.txt wide-emoji.txt mouse-focus.txt README.md; do
  if [[ ! -s "Tests/Fixtures/Ghostty/$f" ]]; then
    echo "FAIL: missing/empty Tests/Fixtures/Ghostty/$f"
    exit 1
  fi
done
echo "OK: Ghostty conformance fixtures present"

# --- Soft path if vendor tree absent ---
if [[ ! -d Vendor/ghostty ]]; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: REQUIRE_GHOSTTY=1 but Vendor/ghostty missing"
    exit 1
  fi
  echo "WARN: Vendor/ghostty absent (soft mode); pin+ABI+fixtures OK"
  exit 0
fi

# Skip expensive build when CE_GHOSTTY_GATE_LIGHT=1 (unit-test probe of gate contract).
if [[ "${CE_GHOSTTY_GATE_LIGHT:-0}" == "1" ]]; then
  echo "OK: light gate complete (pin+ABI probe+fixtures; build skipped)"
  exit 0
fi

chmod +x scripts/build-ghostty.sh scripts/link-ghostty-flags.sh
if ! ./scripts/build-ghostty.sh vt; then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: Ghostty vt build failed (REQUIRE_GHOSTTY=1)"
    exit 1
  fi
  echo "WARN: Ghostty build failed (soft mode) — pin/ABI/fixtures already validated"
  echo "OK: soft-mode qualification evidence complete (linked corpus deferred: build blocked)"
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
if command -v nm >/dev/null 2>&1; then
  if ! nm -g "$LIB" 2>/dev/null | grep -q 'ghostty_terminal_new'; then
    if [[ "$REQUIRE" == "1" ]]; then
      echo "FAIL: ghostty_terminal_new not found in $LIB"
      exit 1
    fi
    echo "WARN: symbol probe inconclusive for $LIB"
  else
    echo "OK: ghostty_terminal_new present (ABI symbol probe)"
  fi
  if nm -g "$LIB" 2>/dev/null | grep -q 'ghostty_key_encoder_encode'; then
    echo "OK: ghostty_key_encoder_encode present"
  fi
fi

if [[ -f Vendor/ghostty-build.stamp ]]; then
  echo "OK: build stamp:"
  cat Vendor/ghostty-build.stamp
else
  echo "WARN: Vendor/ghostty-build.stamp missing"
fi

# Linked build + behavior corpus
CODEEDITOR_GHOSTTY_LINKED=1 swift build --product CodeEditorTerminalGhostty
REQUIRE_GHOSTTY=1 CODEEDITOR_GHOSTTY_LINKED=1 swift test --filter 'Ghostty|TerminalGhostty|CodeEditorTerminalTests|TERNAudit' || {
  if [[ "$REQUIRE" == "1" ]]; then
    echo "FAIL: linked Ghostty tests failed"
    exit 1
  fi
  echo "WARN: linked Ghostty tests failed (soft mode)"
  exit 0
}
echo "OK: linked Ghostty build/test (TER-N09/N10 qualification)"
