#!/usr/bin/env bash
# Resolve/build example packages (RC docs/examples gate).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
for ex in Examples/SmallEditor Examples/FullWorkbench Examples/CodeEditorViewDemo; do
  if [[ ! -f "$ex/Package.swift" ]]; then
    echo "FAIL: missing $ex/Package.swift"
    fail=1
    continue
  fi
  echo "== $ex resolve =="
  if (cd "$ex" && swift package resolve) >/tmp/ex-resolve.log 2>&1; then
    echo "OK:   $ex resolve"
  else
    echo "FAIL: $ex resolve (see /tmp/ex-resolve.log)"
    fail=1
  fi
done
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "Examples check passed"
