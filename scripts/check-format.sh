#!/usr/bin/env bash
# Formatting gate (hard). Missing tool or lint findings fail the job.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift-format >/dev/null 2>&1; then
  echo "FAIL: swift-format not installed" >&2
  echo "      Install: brew install swift-format" >&2
  echo "      Or use a Swift toolchain that provides swift-format on PATH." >&2
  exit 1
fi

CONFIG=()
if [[ -f .swift-format ]]; then
  CONFIG=(--configuration .swift-format)
fi

echo "== swift-format lint (Sources Tests) =="
set +e
swift-format lint --recursive "${CONFIG[@]}" Sources Tests 2>&1 | tee /tmp/codeeditor-format.log
lint_ec=${PIPESTATUS[0]}
set -e

if [[ "$lint_ec" -ne 0 ]]; then
  echo "FAIL: swift-format lint exit $lint_ec" >&2
  exit 1
fi

# Some swift-format versions print findings but still exit 0; treat any output as failure.
if [[ -s /tmp/codeeditor-format.log ]]; then
  # Ignore pure info lines if any; fail on any path-like or error content.
  if grep -E '\.swift:[0-9]+:|error:|warning:' /tmp/codeeditor-format.log >/dev/null 2>&1; then
    echo "FAIL: formatting issues reported" >&2
    exit 1
  fi
fi

echo "OK:   swift-format clean"
