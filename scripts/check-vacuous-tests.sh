#!/usr/bin/env bash
# QUAL-001 / §26.6 — ban vacuous success assertions in Tests/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# Always-true expect
if rg -n --glob '*.swift' '#expect\(\s*true\s*\)' Tests; then
  echo "FAIL: #expect(true) is banned (QUAL-001)"
  fail=1
fi

# #expect(... || true) / #expect(true || ...)
if rg -n --glob '*.swift' '#expect\([^)]*\|\|\s*true' Tests; then
  echo "FAIL: '#expect(... || true)' success paths are banned (QUAL-001)"
  fail=1
fi

# Standalone soft-or used as boolean success (not in comments/strings): match statement forms
# e.g. `condition || true` as expression result, XCTAssert(x || true)
if rg -n --glob '*.swift' -e 'XCTAssert(true)' -e 'XCTAssert\([^)]*\|\|\s*true' Tests; then
  echo "FAIL: XCTAssert(true) / XCTAssert(...|| true) banned"
  fail=1
fi

if rg -n --glob '*.swift' 'true\s*==\s*false' Tests; then
  echo "FAIL: tautology true==false patterns banned"
  fail=1
fi
if rg -n --glob '*.swift' '#expect\(\s*1\s*==\s*1\s*\)' Tests; then
  echo "FAIL: tautology #expect(1 == 1) banned"
  fail=1
fi
if rg -n --glob '*.swift' 'XCTSkip\(\s*\)' Tests; then
  echo "FAIL: empty XCTSkip() banned"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "OK:   no vacuous test success patterns in Tests/"
exit 0
