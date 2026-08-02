#!/usr/bin/env bash
# REL-N04 — accessibility gate: hierarchy/keyboard/rotor/Switch Control automation + manual protocol.
# No token-grep-only pass. Swift tests always run (no skip escape hatch).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

req_files=(
  Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift
  Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift
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
AUTO="Sources/CodeEditorWorkbench/WorkbenchAccessibilityAutomation.swift"
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

if [[ -f "$AUTO" ]]; then
  for token in WorkbenchAccessibilitySession moveFocus rotorQuery switchControl fullKeyboardAccess reduceMotion WorkbenchAccessibilityContentSource; do
    if ! grep -q "$token" "$AUTO"; then
      echo "FAIL: automation missing $token"
      fail=1
    fi
  done
  if grep -q 'seedRotorCatalog' "$AUTO"; then
    echo "FAIL: hardcoded seedRotorCatalog must not ship in production automation"
    fail=1
  fi
  if grep -q 'switchControlEnabled || true' "$AUTO"; then
    echo "FAIL: Switch Control soft-allow (|| true) is forbidden"
    fail=1
  fi
  if ! grep -q 'switchControlDisabled' "$AUTO"; then
    echo "FAIL: Switch Control must fail closed via switchControlDisabled error path"
    fail=1
  fi
  if ! grep -qE 'accessibilityChildren|NSHostingView' "$AUTO"; then
    echo "FAIL: TreeProbe must walk AppKit AX (accessibilityChildren / NSHostingView)"
    fail=1
  fi
  if grep -q 'let viewDeclared: \[String\] = \[' "$AUTO"; then
    echo "FAIL: TreeProbe must not hardcode chrome ID catalog as AX substitute"
    fail=1
  fi
  echo "OK:   accessibility automation session API present (content-sourced, fail-closed, live AX)"
else
  echo "FAIL: WorkbenchAccessibilityAutomation.swift required for XCUI-equivalent coverage"
  fail=1
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

if [[ -f Docs/Architecture/ACCESSIBILITY-SIGNOFF.md ]]; then
  if ! grep -qiE 'IME|screen reader|VoiceOver|Switch Control|Dynamic Type|high contrast' Docs/Architecture/ACCESSIBILITY-SIGNOFF.md; then
    echo "FAIL: ACCESSIBILITY-SIGNOFF.md missing required manual scenarios"
    fail=1
  else
    echo "OK:   manual sign-off protocol present"
  fi
  # Automation must cover keyboard/rotor/switch; manual only for IME/screen-reader residual
  if ! grep -qiE 'automat' Docs/Architecture/ACCESSIBILITY-SIGNOFF.md; then
    echo "FAIL: ACCESSIBILITY-SIGNOFF.md must document automated vs manual split"
    fail=1
  fi
fi

if ! grep -R -q "WorkbenchAccessibilitySession\|test_REL_N04" Tests --include='*.swift'; then
  echo "FAIL: no executable WorkbenchAccessibilitySession automation tests"
  fail=1
else
  echo "OK:   executable accessibility automation tests present"
fi

# Always run focused workbench automation suite (no skip escape hatch).
# Filter Phase16AccessibilityTests only — never REL_N04 globally (would nest
# ReleaseTruthTests that re-invoke swift test and hang under load).
echo "== swift test --filter Phase16AccessibilityTests =="
export CODEEDITOR_IN_A11Y_GATE=1
# Prefer --skip-build to avoid nested SwiftPM lock deadlocks when already under swift test.
if [[ -d "$ROOT/.build" ]]; then
  A11Y_CMD=(swift test --skip-build --filter Phase16AccessibilityTests)
else
  A11Y_CMD=(swift test --filter Phase16AccessibilityTests)
fi
if ! "${A11Y_CMD[@]}" 2>&1 | tee /tmp/a11y-swift-test.log | tail -40; then
  if ! swift test --filter Phase16AccessibilityTests 2>&1 | tee /tmp/a11y-swift-test.log | tail -40; then
    echo "FAIL: accessibility automation swift tests failed"
    fail=1
  fi
fi
if ! grep -Eqi 'passed|Test run' /tmp/a11y-swift-test.log; then
  # swift-testing formats vary; exit code is authoritative
  :
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Accessibility check FAILED"
  exit 1
fi
echo "Accessibility check passed"
