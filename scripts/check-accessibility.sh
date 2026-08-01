#!/usr/bin/env bash
# Automated accessibility surface checks for Workbench/View (Phase 8/16).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

req_files=(
  Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift
)
for f in "${req_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    fail=1
  else
    echo "OK:   $f"
  fi
done

# Required identifiers must be defined and referenced
for id in root toolbar activityBar navigator editor inspector statusBar commandPalette; do
  if ! grep -q "$id" Sources/CodeEditorWorkbench/WorkbenchAccessibility.swift 2>/dev/null; then
    echo "FAIL: WorkbenchAccessibility missing id token $id"
    fail=1
  fi
done

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

if [[ "$fail" -ne 0 ]]; then
  echo "Accessibility check FAILED"
  exit 1
fi
echo "Accessibility check passed"
