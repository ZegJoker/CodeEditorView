#!/usr/bin/env bash
# REL-N04 — accessibility gate beyond source-token grep.
# Requires hierarchy/focus/rotor model, executable tests, and manual sign-off protocol.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

req_files=(
  Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift
  Docs/Architecture/ACCESSIBILITY-SIGNOFF.md
)
for f in "${req_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    fail=1
  else
    echo "OK:   $f"
  fi
done

A11Y="Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift"
if [[ -f "$A11Y" ]]; then
  for token in WorkbenchAccessibilityHierarchy WorkbenchFocusOrder rotor keyboard; do
    if ! grep -q "$token" "$A11Y"; then
      echo "FAIL: $A11Y missing hierarchy/focus token: $token"
      fail=1
    fi
  done
  for surface in errors symbols folds breakpoints search; do
    if ! grep -qi "$surface" "$A11Y"; then
      echo "FAIL: accessibility hierarchy missing rotor surface: $surface"
      fail=1
    fi
  done
fi

if ! grep -R -q "accessibilityIdentifier" Sources/CodeEditorWorkbench --include='*.swift'; then
  echo "FAIL: no accessibilityIdentifier usage in Workbench"
  fail=1
else
  echo "OK:   accessibilityIdentifier usage present"
fi

if ! grep -R -q "accessibilityReduceMotion\|ReduceMotion" Sources/CodeEditorWorkbench --include='*.swift'; then
  echo "FAIL: reduce-motion handling not found in Workbench"
  fail=1
else
  echo "OK:   reduce-motion handling present"
fi

# Manual sign-off protocol must list IME + screen reader scenarios
if [[ -f Docs/Architecture/ACCESSIBILITY-SIGNOFF.md ]]; then
  if ! grep -qiE 'IME|screen reader|VoiceOver|Switch Control|Dynamic Type|high contrast' Docs/Architecture/ACCESSIBILITY-SIGNOFF.md; then
    echo "FAIL: ACCESSIBILITY-SIGNOFF.md missing required manual scenarios"
    fail=1
  else
    echo "OK:   manual sign-off protocol present"
  fi
fi

# Executable accessibility tests (hierarchy model + Phase 16 IDs)
if ! grep -R -q "WorkbenchAccessibility\|AccessibilityHierarchy\|Phase16Accessibility\|REL_N04\|test_REL_N04" Tests --include='*.swift'; then
  echo "FAIL: no executable accessibility tests under Tests/"
  fail=1
else
  echo "OK:   executable accessibility tests referenced"
fi

# Run focused swift tests when not skipped for fixture-only hosts
if [[ "${A11Y_SKIP_SWIFT_TEST:-0}" != "1" ]]; then
  echo "== swift test --filter Phase16Accessibility =="
  if ! swift test --filter Phase16Accessibility 2>&1 | tail -30; then
    echo "FAIL: accessibility swift tests failed"
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Accessibility check FAILED"
  exit 1
fi
echo "Accessibility check passed"
