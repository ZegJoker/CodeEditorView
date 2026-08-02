#!/usr/bin/env bash
# §26.6 sanitizer job — hard ASan (and TSan) build of CodeEditorCore.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "FAIL: swift not on PATH"
  exit 1
fi

echo "== ASan build CodeEditorCore =="
if ! swift build --product CodeEditorCore -Xswiftc -sanitize=address 2>/tmp/asan-build.log; then
  echo "FAIL: ASan build failed"
  tail -40 /tmp/asan-build.log
  exit 1
fi
echo "OK:   CodeEditorCore ASan build"

echo "== TSan build CodeEditorCore =="
if ! swift build --product CodeEditorCore -Xswiftc -sanitize=thread 2>/tmp/tsan-build.log; then
  echo "FAIL: TSan build failed"
  tail -40 /tmp/tsan-build.log
  exit 1
fi
echo "OK:   CodeEditorCore TSan build"

echo "OK:   sanitizer shell hard mode (ASan+TSan product builds)"
exit 0
