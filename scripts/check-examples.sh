#!/usr/bin/env bash
# Resolve/build example packages + Xcode 26 host gates (Phase 1).
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

MAC_EX="Examples/macOS/CodeEditorMacExample"
IOS_EX="Examples/iOS/CodeEditoriOSExample"

if [[ ! -f "$MAC_EX/Package.swift" ]]; then
  echo "FAIL: missing $MAC_EX/Package.swift"
  fail=1
else
  echo "== macOS example: swift test =="
  if (cd "$MAC_EX" && swift test) 2>&1 | tee /tmp/mac-example-test.log; then
    echo "OK:   macOS example swift test"
  else
    echo "FAIL: macOS example swift test"
    fail=1
  fi

  echo "== macOS example: xcodebuild test =="
  if command -v xcodebuild >/dev/null 2>&1; then
    DD="$(mktemp -d /tmp/ce-mac-dd-XXXXXX)"
    if (
      cd "$MAC_EX"
      xcodebuild \
        -scheme CodeEditorMacExample \
        -destination 'platform=macOS' \
        -derivedDataPath "$DD" \
        test
    ) 2>&1 | tee /tmp/mac-example-xcodebuild.log; then
      echo "OK:   macOS example xcodebuild test"
    else
      echo "FAIL: macOS example xcodebuild test"
      fail=1
    fi
    rm -rf "$DD"
  else
    echo "FAIL: xcodebuild required for macOS example gate"
    fail=1
  fi
fi

if [[ ! -f "$IOS_EX/Package.swift" ]]; then
  echo "FAIL: missing $IOS_EX/Package.swift"
  fail=1
else
  echo "== iOS example: xcodebuild build+test (simulator) =="
  if command -v xcodebuild >/dev/null 2>&1; then
    DD="$(mktemp -d /tmp/ce-ios-dd-XXXXXX)"
    # Prefer a concrete simulator; fall back to generic iOS Simulator destination.
    DEST="platform=iOS Simulator,name=iPhone 16"
    if ! xcrun simctl list devices available 2>/dev/null | grep -q "iPhone 16"; then
      DEST="generic/platform=iOS Simulator"
    fi
    if (
      cd "$IOS_EX"
      xcodebuild \
        -scheme CodeEditoriOSExample \
        -destination "$DEST" \
        -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        test
    ) 2>&1 | tee /tmp/ios-example-xcodebuild.log; then
      echo "OK:   iOS example xcodebuild test"
    else
      echo "FAIL: iOS example xcodebuild test"
      fail=1
    fi
    rm -rf "$DD"
  else
    echo "FAIL: xcodebuild required for iOS example gate"
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
echo "Examples check passed"
