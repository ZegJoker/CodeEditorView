#!/usr/bin/env bash
# UI-N08 — platform build/runtime matrix hard gate.
# Fails closed when matrix documentation or package platforms drift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

MATRIX="Docs/Architecture/PLATFORM-MATRIX.md"
PKG="Package.swift"

if [[ ! -f "$MATRIX" ]]; then
  echo "FAIL: missing $MATRIX"
  fail=1
else
  echo "OK:   $MATRIX"
  for token in "macOS 15" "iOS 18" "Apple silicon" "silicon"; do
    if ! grep -qi "$token" "$MATRIX"; then
      echo "FAIL: $MATRIX missing required token: $token"
      fail=1
    fi
  done
  if ! grep -qi "Intel" "$MATRIX"; then
    echo "FAIL: $MATRIX must document Intel policy (not promised / silicon-only)"
    fail=1
  fi
fi

if [[ ! -f "$PKG" ]]; then
  echo "FAIL: missing $PKG"
  fail=1
else
  if ! grep -qE '\.macOS\(\.v15\)|macOS\(\.v15\)' "$PKG"; then
    echo "FAIL: Package.swift must declare macOS 15+"
    fail=1
  else
    echo "OK:   Package.swift macOS 15+"
  fi
  if ! grep -qE '\.iOS\(\.v18\)|iOS\(\.v18\)' "$PKG"; then
    echo "FAIL: Package.swift must declare iOS 18+"
    fail=1
  else
    echo "OK:   Package.swift iOS 18+"
  fi
fi

# Regression suite must encode UI-N08 checks.
TEST="Tests/CodeEditorViewTests/UINAuditTests.swift"
if [[ ! -f "$TEST" ]]; then
  echo "FAIL: missing $TEST (UI-N08 regression tests)"
  fail=1
else
  if ! grep -q 'test_UI_N08_' "$TEST"; then
    echo "FAIL: $TEST missing test_UI_N08_ regression tests"
    fail=1
  else
    echo "OK:   UI-N08 regression tests present"
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "UI-N08 platform matrix gate FAILED"
  exit 1
fi
echo "UI-N08 platform matrix gate OK"
exit 0
