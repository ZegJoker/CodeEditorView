#!/usr/bin/env bash
# Build Ghostty libraries at the pinned commit into Vendor/ghostty/zig-out.
# Requires: git, zig matching Ghostty's minimum version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/Docs/Architecture/GHOSTTY.pin" 2>/dev/null || true
PIN_FILE="$ROOT/Docs/Architecture/GHOSTTY.pin"
COMMIT="$(grep '^GHOSTTY_COMMIT=' "$PIN_FILE" | cut -d= -f2- | tr -d '[:space:]')"
REPO="$(grep '^GHOSTTY_REPO=' "$PIN_FILE" | cut -d= -f2- | tr -d '[:space:]')"
VENDOR="$ROOT/Vendor/ghostty"
MODE="${1:-vt}" # vt | full

if ! command -v zig >/dev/null 2>&1; then
  echo "FAIL: zig not found (install Zig matching Ghostty minimum)"
  exit 1
fi

echo "Ghostty pin: $COMMIT"
mkdir -p "$ROOT/Vendor"
if [[ ! -d "$VENDOR/.git" ]]; then
  git clone --filter=blob:none "$REPO" "$VENDOR"
fi
cd "$VENDOR"
git fetch --depth 1 origin "$COMMIT" 2>/dev/null || git fetch origin "$COMMIT"
git checkout --detach "$COMMIT"

echo "Building Ghostty ($MODE) with $(zig version)..."
case "$MODE" in
  vt)
    zig build -Demit-lib-vt=true -Doptimize=ReleaseFast
    ;;
  full)
    zig build -Dapp-runtime=none -Doptimize=ReleaseFast
    ;;
  *)
    echo "usage: $0 [vt|full]"
    exit 2
    ;;
esac

echo "OK: Ghostty build finished. Artifacts under $VENDOR/zig-out"
ls -la "$VENDOR/zig-out/lib" 2>/dev/null || ls -la "$VENDOR/zig-out" || true

# Stamp for SwiftPM / CI detection
echo "$COMMIT" > "$ROOT/Vendor/ghostty-build.stamp"
echo "MODE=$MODE" >> "$ROOT/Vendor/ghostty-build.stamp"
echo "ZIG=$(zig version)" >> "$ROOT/Vendor/ghostty-build.stamp"
