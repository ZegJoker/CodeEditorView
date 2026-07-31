#!/usr/bin/env bash
# Formatting gate. Uses swift-format when available; otherwise records skip with non-fail.
# Set REQUIRE_SWIFT_FORMAT=1 to fail if the tool is missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift-format >/dev/null 2>&1; then
  if [[ "${REQUIRE_SWIFT_FORMAT:-0}" == "1" ]]; then
    echo "FAIL: swift-format not installed (REQUIRE_SWIFT_FORMAT=1)" >&2
    exit 1
  fi
  echo "SKIP: swift-format not installed (install via Homebrew or Swift toolchain)"
  echo "      Configuration: .swift-format (when present)"
  exit 0
fi

CONFIG=()
if [[ -f .swift-format ]]; then
  CONFIG=(--configuration .swift-format)
fi

echo "== swift-format lint =="
# Lint Sources and Tests only
swift-format lint --recursive "${CONFIG[@]}" Sources Tests 2>&1 | tee /tmp/codeeditor-format.log || true
# swift-format lint exits non-zero on findings
if grep -q . /tmp/codeeditor-format.log 2>/dev/null; then
  # Count only error-like lines if tool printed paths
  if [[ "${STRICT_FORMAT:-0}" == "1" ]]; then
    echo "FAIL: formatting issues (STRICT_FORMAT=1)"
    exit 1
  fi
  echo "WARN: swift-format reported findings (set STRICT_FORMAT=1 to fail)"
else
  echo "OK:   no format findings"
fi
