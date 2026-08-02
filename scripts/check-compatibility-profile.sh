#!/usr/bin/env bash
# REL-N01 — CompatibilityProfile must be CI-generated with real IDs (not unpinned hand-authorship).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROFILE="${COMPAT_PROFILE:-Docs/Architecture/CompatibilityProfile.toml}"
fail=0

if [[ ! -f "$PROFILE" ]]; then
  echo "FAIL: missing $PROFILE — run scripts/generate-compatibility-profile.sh"
  exit 1
fi

if grep -q 'phase-16-rc' "$PROFILE"; then
  echo "FAIL: profile claims phase-16-rc"
  fail=1
fi

if ! grep -Eq 'status = "(pre-alpha|experimental)"' "$PROFILE"; then
  echo "FAIL: status must be pre-alpha or experimental"
  fail=1
fi

if grep -Eq 'upstream_commit = "unpinned"' "$PROFILE"; then
  echo "FAIL: upstream_commit is unpinned — regenerate via generate-compatibility-profile.sh"
  fail=1
fi

if ! grep -Eq 'upstream_commit = "[0-9a-f]{40}"' "$PROFILE"; then
  echo "FAIL: upstream_commit must be a 40-char git SHA"
  fail=1
fi

for key in toolchain_swift toolchain_xcode test_suite_version generated_at generator; do
  if ! grep -q "$key" "$PROFILE"; then
    echo "FAIL: profile missing generation field: $key"
    fail=1
  fi
done

for axis in schema_support source_compatibility behavioral_conformance security_qualification operational_qualification; do
  if ! grep -q "$axis" "$PROFILE"; then
    echo "FAIL: missing qualification axis $axis"
    fail=1
  fi
done

# Must not mass-claim stable or passing
if grep -E '^\s*[a-z_]+ = "stable"' "$PROFILE" | grep -v '^#' >/dev/null 2>&1; then
  echo "FAIL: pre-alpha profile must not mark features stable"
  fail=1
fi
if grep -E ' = "passing"' "$PROFILE" >/dev/null 2>&1; then
  echo "FAIL: must not author passing qualification"
  fail=1
fi

if ! grep -q 'generate-compatibility-profile.sh' "$PROFILE"; then
  echo "FAIL: profile must record generator script (CI-generated)"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "Compatibility profile check FAILED"
  exit 1
fi
echo "OK: CompatibilityProfile honesty + generation IDs validated"
