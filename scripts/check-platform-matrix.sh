#!/usr/bin/env bash
# UI-N08 — platform build/runtime matrix hard gate.
# Fails closed when matrix documentation, package platforms, or real build evidence is missing.
# Runs real Xcode/Swift builds when tools are available; never treats greps alone as evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0

MATRIX="Docs/Architecture/PLATFORM-MATRIX.md"
PKG="Package.swift"
EVIDENCE_DIR="Baselines/evidence"
EVIDENCE_FILE="$EVIDENCE_DIR/platform-matrix.json"
mkdir -p "$EVIDENCE_DIR"

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

# --- Real build / runtime evidence (not documentation alone) ---
host_arch="$(uname -m)"
host_os="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
xcode_ver="missing"
macos_build="fail"
ios_sim_build="fail"
macos_xcodebuild="skipped"
ios_xcodebuild="skipped"
swift_host_test="fail"

if [[ "$host_arch" != "arm64" ]]; then
  echo "FAIL: Apple silicon-only matrix policy; host arch is $host_arch"
  fail=1
else
  echo "OK:   host arch arm64 (Apple silicon)"
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "FAIL: xcodebuild required for UI-N08 platform matrix evidence"
  fail=1
else
  xcode_ver="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  echo "OK:   xcodebuild present ($xcode_ver)"
fi

# Optional isolated scratch path avoids deadlock when this script is invoked from
# inside `swift test` (which already holds the package `.build` lock).
SCRATCH_ARGS=()
if [[ -n "${PLATFORM_MATRIX_SCRATCH_PATH:-}" ]]; then
  mkdir -p "$PLATFORM_MATRIX_SCRATCH_PATH"
  SCRATCH_ARGS=(--scratch-path "$PLATFORM_MATRIX_SCRATCH_PATH")
  echo "OK:   using isolated scratch path $PLATFORM_MATRIX_SCRATCH_PATH"
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "FAIL: swift toolchain required"
  fail=1
else
  echo "== Host macOS: swift build --target CodeEditorView =="
  if swift build --target CodeEditorView "${SCRATCH_ARGS[@]}" >/tmp/uin08-macos-build.log 2>&1; then
    macos_build="pass"
    echo "OK:   macOS swift build CodeEditorView"
  else
    echo "FAIL: macOS swift build (see /tmp/uin08-macos-build.log)"
    fail=1
  fi
  # Unit contracts are enforced by CI `swift test` / CodeEditorViewTests — do not re-enter
  # `swift test` here (would recurse when regression tests invoke this script).
  swift_host_test="delegated_to_swift_test"
fi

# iOS Simulator triple build of CodeEditorView (runtime class iOS 18+).
# Build --target CodeEditorView only so macOS-only CGhosttyShim is not required.
if command -v xcrun >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then
  if SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"; then
    echo "== iOS Simulator: swift build --target CodeEditorView (ios18 sim) =="
    if swift build \
      --target CodeEditorView \
      --triple arm64-apple-ios18.0-simulator \
      -Xswiftc -sdk -Xswiftc "$SDK" \
      -Xcc -isysroot -Xcc "$SDK" \
      "${SCRATCH_ARGS[@]}" \
      >/tmp/uin08-ios-sim-build.log 2>&1; then
      ios_sim_build="pass"
      echo "OK:   iOS Simulator triple build CodeEditorView"
    else
      echo "FAIL: iOS Simulator triple build (see /tmp/uin08-ios-sim-build.log)"
      fail=1
    fi
  else
    echo "FAIL: iphonesimulator SDK not available"
    fail=1
  fi
else
  echo "FAIL: xcrun/swift required for iOS simulator build evidence"
  fail=1
fi

# Optional (CI / full matrix): real example host xcodebuild test evidence.
# PLATFORM_MATRIX_XCODEBUILD=1 (default when CI=true) runs macOS + iOS example xcodebuild builds.
run_xcode="${PLATFORM_MATRIX_XCODEBUILD:-}"
if [[ -n "${CI:-}" && -z "$run_xcode" ]]; then
  run_xcode=1
fi
if [[ "${run_xcode}" == "1" || "${run_xcode}" == "true" ]]; then
  MAC_EX="Examples/macOS/CodeEditorMacExample"
  IOS_EX="Examples/iOS/CodeEditoriOSExample"
  if command -v xcodebuild >/dev/null 2>&1; then
    if [[ -f "$MAC_EX/Package.swift" ]]; then
      echo "== macOS example: xcodebuild build =="
      DD="$(mktemp -d /tmp/ce-mac-matrix-XXXXXX)"
      if (
        cd "$MAC_EX"
        xcodebuild \
          -scheme CodeEditorMacExample \
          -destination 'platform=macOS' \
          -derivedDataPath "$DD" \
          build
      ) >/tmp/uin08-mac-xcodebuild.log 2>&1; then
        macos_xcodebuild="pass"
        echo "OK:   macOS example xcodebuild build"
      else
        macos_xcodebuild="fail"
        echo "FAIL: macOS example xcodebuild build (see /tmp/uin08-mac-xcodebuild.log)"
        fail=1
      fi
      rm -rf "$DD"
    else
      echo "FAIL: missing $MAC_EX"
      macos_xcodebuild="fail"
      fail=1
    fi

    if [[ -f "$IOS_EX/Package.swift" ]]; then
      echo "== iOS example: xcodebuild build (simulator) =="
      DD="$(mktemp -d /tmp/ce-ios-matrix-XXXXXX)"
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
          build
      ) >/tmp/uin08-ios-xcodebuild.log 2>&1; then
        ios_xcodebuild="pass"
        echo "OK:   iOS example xcodebuild build"
      else
        ios_xcodebuild="fail"
        echo "FAIL: iOS example xcodebuild build (see /tmp/uin08-ios-xcodebuild.log)"
        fail=1
      fi
      rm -rf "$DD"
    else
      echo "FAIL: missing $IOS_EX"
      ios_xcodebuild="fail"
      fail=1
    fi
  fi
else
  echo "NOTE: PLATFORM_MATRIX_XCODEBUILD not set — skipping example xcodebuild (CI sets this)"
fi

# Write structured evidence artifact (required by regression tests).
cat >"$EVIDENCE_FILE" <<EOF
{
  "finding": "UI-N08",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host_arch": "$host_arch",
  "host_os": "$host_os",
  "xcode_version": "$xcode_ver",
  "silicon_only_policy": true,
  "package_platforms": ["macOS15", "iOS18"],
  "results": {
    "macos_swift_build": "$macos_build",
    "macos_swift_test_uin0": "$swift_host_test",
    "ios_simulator_swift_build": "$ios_sim_build",
    "macos_example_xcodebuild": "$macos_xcodebuild",
    "ios_example_xcodebuild": "$ios_xcodebuild"
  }
}
EOF
echo "OK:   wrote $EVIDENCE_FILE"

# Hard-require core evidence paths.
if [[ "$macos_build" != "pass" || "$ios_sim_build" != "pass" ]]; then
  echo "FAIL: core platform builds did not pass"
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "UI-N08 platform matrix gate FAILED"
  exit 1
fi
echo "UI-N08 platform matrix gate OK"
exit 0
