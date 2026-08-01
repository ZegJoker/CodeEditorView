#!/usr/bin/env bash
# CI-009: require exact Xcode marketing version from Docs/Architecture/XCODE.pin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PIN_FILE="Docs/Architecture/XCODE.pin"
if [[ ! -f "$PIN_FILE" ]]; then
  echo "FAIL: missing $PIN_FILE" >&2
  exit 1
fi

want_version="$(grep -E '^XCODE_VERSION=' "$PIN_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
want_build="$(grep -E '^XCODE_BUILD=' "$PIN_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"
dev_dir="$(grep -E '^DEVELOPER_DIR=' "$PIN_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')"

if [[ -n "$dev_dir" && -d "$dev_dir" ]]; then
  export DEVELOPER_DIR="$dev_dir"
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "FAIL: xcodebuild not on PATH" >&2
  exit 1
fi

xcode_out="$(xcodebuild -version 2>&1)"
echo "$xcode_out"
swift --version 2>&1 | head -2 || true

got_version="$(echo "$xcode_out" | awk '/^Xcode /{print $2; exit}')"
got_build="$(echo "$xcode_out" | awk '/Build version/{print $3; exit}')"

if [[ -z "$want_version" ]]; then
  echo "FAIL: XCODE_VERSION empty in pin" >&2
  exit 1
fi

if [[ "$got_version" != "$want_version" ]]; then
  echo "FAIL: Xcode version mismatch: got '$got_version' want '$want_version'" >&2
  exit 1
fi

if [[ -n "$want_build" && "$got_build" != "$want_build" ]]; then
  echo "WARN: Xcode build mismatch: got '$got_build' want '$want_build' (marketing version OK)"
  # Build number may drift on CI images; marketing version is the hard gate.
fi

echo "OK:   Xcode $got_version (build $got_build) matches pin"
