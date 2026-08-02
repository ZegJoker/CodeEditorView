#!/usr/bin/env bash
# Build Ghostty libraries at the pinned commit into Vendor/ghostty/zig-out.
# Requires: git, zig matching Ghostty's minimum version, curl (for deps.files seed).
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

# Zig's HTTP client often gets 400 from deps.files.ghostty.org; curl + zig fetch
# seeds the package cache so `zig build` can resolve offline (TER-N10 reproducible).
seed_ghostty_deps() {
  local depdir="${GHOSTTY_DEP_CACHE:-/tmp/ghostty-deps}"
  mkdir -p "$depdir"
  python3 - "$VENDOR" "$depdir" <<'PY'
import re, pathlib, subprocess, sys, urllib.request
vendor, depdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
urls = set()
for p in vendor.rglob("*.zon"):
    try:
        t = p.read_text(errors="ignore")
    except Exception:
        continue
    for m in re.finditer(r"https://deps\.files\.ghostty\.org/[^\"\s]+", t):
        urls.add(m.group(0))
print(f"seeding {len(urls)} deps.files packages into zig cache...", flush=True)
for url in sorted(urls):
    name = url.rsplit("/", 1)[-1]
    path = depdir / name
    if not path.is_file() or path.stat().st_size == 0:
        print(f"  curl {name}", flush=True)
        try:
            urllib.request.urlretrieve(url, path)
        except Exception as e:
            print(f"  WARN: download failed {name}: {e}", flush=True)
            continue
    r = subprocess.run(["zig", "fetch", f"file://{path}"], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  WARN: zig fetch {name}: {r.stderr.strip()[:200]}", flush=True)
PY
}

seed_ghostty_deps || echo "WARN: dep seed incomplete; zig build may still fetch"

echo "Building Ghostty ($MODE) with $(zig version)..."
case "$MODE" in
  vt)
    if ! zig build -Demit-lib-vt=true -Doptimize=ReleaseFast; then
      echo "retry after re-seed..."
      seed_ghostty_deps || true
      zig build -Demit-lib-vt=true -Doptimize=ReleaseFast
    fi
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
