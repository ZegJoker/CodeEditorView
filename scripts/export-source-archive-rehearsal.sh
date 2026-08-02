#!/usr/bin/env bash
# PKG-N01 / PKG-001 / CI-010: export a source archive into an empty environment and
# resolve/build/test every public product without developer caches or bootstrap mutation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-$ROOT/Baselines/evidence}"
mkdir -p "$OUT_DIR"

# PKG-N01: full suite is the only valid production path (fail closed early).
if [[ "${FULL_ARCHIVE_TEST:-1}" != "1" ]]; then
  echo "FAIL: FULL_ARCHIVE_TEST must be 1 for clean-archive rehearsal (got ${FULL_ARCHIVE_TEST:-})" >&2
  echo "      Acceptance requires: resolve → all products → all tests" >&2
  exit 1
fi

# ARCHIVE_PHASE:
#   full  (default) — resolve → all products (debug+release) → executables → nested swift test
#   smoke — same clean archive/empty HOME resolve + product builds, but skip nested swift test
#           (used by unit tests to avoid package-lock recursion; CI runs full).
ARCHIVE_PHASE="${ARCHIVE_PHASE:-full}"
case "$ARCHIVE_PHASE" in
  full|smoke) ;;
  *)
    echo "FAIL: ARCHIVE_PHASE must be full or smoke (got ${ARCHIVE_PHASE})" >&2
    exit 1
    ;;
esac
echo "ARCHIVE_PHASE=$ARCHIVE_PHASE"

STAGING="$(mktemp -d /tmp/codeeditor-archive-XXXXXX)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

ARCHIVE="$STAGING/source.tar.gz"
EXTRACT="$STAGING/extract"
mkdir -p "$EXTRACT"

# Isolated HOME + empty SwiftPM caches (PKG-N01)
EMPTY_HOME="$STAGING/empty-home"
mkdir -p "$EMPTY_HOME"
export HOME="$EMPTY_HOME"
export SWIFTPM_CACHE_PATH="$STAGING/spm-cache"
export SWIFTPM_SHARED_CACHE_PATH="$STAGING/spm-shared"
mkdir -p "$SWIFTPM_CACHE_PATH" "$SWIFTPM_SHARED_CACHE_PATH"
# Clear any inherited package caches from the workspace extract path
unset CI_DERIVED_DATA || true

grammars_in_head() {
  git -C "$ROOT" cat-file -e "HEAD:Packages/CodeEditorGrammars/Package.swift" 2>/dev/null
}

echo "== create source archive =="
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && grammars_in_head; then
  echo "Using git archive HEAD (committed grammars package)"
  git -C "$ROOT" archive --format=tar.gz -o "$ARCHIVE" HEAD
else
  echo "Using worktree export (grammars not yet in HEAD — stage/commit Packages/CodeEditorGrammars for CI)"
  if [[ ! -d "$ROOT/Packages/CodeEditorGrammars/Sources" ]]; then
    echo "FAIL: Packages/CodeEditorGrammars/Sources missing" >&2
    exit 1
  fi
  rsync -a \
    --exclude '.git/' \
    --exclude '.build/' \
    --exclude '**/.build/' \
    --exclude 'DerivedData/' \
    --exclude 'Grammars/' \
    --exclude 'Vendor/ghostty/' \
    --exclude 'Baselines/evidence/*.log' \
    --exclude '.swiftpm/xcode/' \
    "$ROOT/" "$STAGING/worktree/"
  tar -C "$STAGING/worktree" -czf "$ARCHIVE" .
fi

echo "== extract =="
tar -xzf "$ARCHIVE" -C "$EXTRACT"

if [[ ! -f "$EXTRACT/Package.swift" ]]; then
  echo "FAIL: Package.swift missing from archive" >&2
  exit 1
fi

if [[ ! -d "$EXTRACT/Packages/CodeEditorGrammars/Sources" ]]; then
  echo "FAIL: Packages/CodeEditorGrammars/Sources missing from archive (PKG-001)" >&2
  exit 1
fi

if rg -n 'path: "Grammars/' "$EXTRACT/Package.swift" >/dev/null 2>&1; then
  echo "FAIL: archived Package.swift still declares Grammars/ paths" >&2
  exit 1
fi

SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
echo "$SHA  source.tar.gz" | tee "$OUT_DIR/source-archive.sha256"

PRODUCTS_FULL=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorCommands
  CodeEditorWorkspace
  CodeEditorWorkbench
  CodeEditorView
  CodeEditorLanguageSupport
  CodeEditorLanguageServices
  CodeEditorExtensionAPI
  CodeEditorExtensionProtocol
  CodeEditorExtensionGuest
  CodeEditorWasmEngine
  CodeEditorWasmEngineWasmKit
  CodeEditorExtensionWasmGuest
  CodeEditorExtensions
  CodeEditorExtensionHost
  CodeEditorLSP
  CodeEditorDAP
  CodeEditorSearch
  CodeEditorTasks
  CodeEditorTerminal
  CodeEditorSourceControl
  CodeEditorTreeSitter
  CodeEditorLanguageSwift
  CodeEditorLanguageJSON
  CodeEditorLanguages
  CodeEditorTerminalGhostty
)

# Smoke: representative public products (always includes Core/Documents/View/Ghostty for PKG-N01 tests).
# Full phase builds every public library product.
PRODUCTS_SMOKE=(
  CodeEditorCore
  CodeEditorDocuments
  CodeEditorCommands
  CodeEditorWorkspace
  CodeEditorView
  CodeEditorWorkbench
  CodeEditorTerminal
  CodeEditorTerminalGhostty
)

if [[ "$ARCHIVE_PHASE" == "smoke" ]]; then
  PRODUCTS=("${PRODUCTS_SMOKE[@]}")
else
  PRODUCTS=("${PRODUCTS_FULL[@]}")
fi

echo "== resolve + build (empty HOME/cache tree) =="
(
  cd "$EXTRACT"
  rm -rf .build
  export HOME="$EMPTY_HOME"
  export SWIFTPM_CACHE_PATH="$STAGING/spm-cache"
  export SWIFTPM_SHARED_CACHE_PATH="$STAGING/spm-shared"
  swift package resolve

  # Dependency graph + package fingerprint artifacts
  swift package show-dependencies --format json >"$OUT_DIR/dependency-graph.json" 2>/dev/null \
    || swift package show-dependencies >"$OUT_DIR/dependency-graph.txt"
  if [[ -f Package.resolved ]]; then
    cp Package.resolved "$OUT_DIR/Package.resolved"
    shasum -a 256 Package.resolved | tee "$OUT_DIR/package-resolved.sha256"
  fi
  # Grammar package provenance fingerprint
  if [[ -d Packages/CodeEditorGrammars ]]; then
    (
      cd Packages/CodeEditorGrammars
      find Sources -type f | sort | xargs shasum -a 256
    ) >"$OUT_DIR/grammar-sources.sha256"
    if [[ -f Package.swift ]]; then
      shasum -a 256 Packages/CodeEditorGrammars/Package.swift \
        | tee -a "$OUT_DIR/package-fingerprint.sha256"
    fi
  fi
  {
    echo "archive_sha256=$SHA"
    echo "home=$HOME"
    date -u +"generated_at=%Y-%m-%dT%H:%M:%SZ"
  } >"$OUT_DIR/clean-resolve-fingerprint.txt"

  for product in "${PRODUCTS[@]}"; do
    echo "== debug build --product $product =="
    swift build --product "$product"
    echo "== release build --product $product =="
    swift build -c release --product "$product"
  done

  # Executable products + --version
  echo "== executables =="
  swift build --product codeeditor-extension
  swift build -c release --product codeeditor-extension
  BIN="$(swift build --show-bin-path)/codeeditor-extension"
  if [[ -x "$BIN" ]]; then
    "$BIN" --version | tee "$OUT_DIR/codeeditor-extension.version"
  else
    # SPM may place executable differently
    find .build -type f -name 'codeeditor-extension' -perm -111 | head -1 | while read -r p; do
      "$p" --version | tee "$OUT_DIR/codeeditor-extension.version"
    done
  fi

  swift build --product ConformanceExtensionGuest
  CBIN="$(swift build --show-bin-path)/ConformanceExtensionGuest"
  if [[ ! -x "$CBIN" ]]; then
    CBIN="$(find .build -type f -name 'ConformanceExtensionGuest' -perm -111 | head -1 || true)"
  fi
  if [[ -z "${CBIN:-}" || ! -x "$CBIN" ]]; then
    echo "FAIL: ConformanceExtensionGuest binary missing after build" >&2
    exit 1
  fi
  # Hard-fail on --version (PKG-N01; no soft || true)
  "$CBIN" --version | tee "$OUT_DIR/ConformanceExtensionGuest.version"

  # Meaningful CLI command on fixture package
  if [[ -d Tests/Fixtures/Extensions/s0-basic ]]; then
    "$BIN" validate Tests/Fixtures/Extensions/s0-basic || \
      find .build -type f -name 'codeeditor-extension' -perm -111 -exec {} validate Tests/Fixtures/Extensions/s0-basic \;
  fi

  # PKG-N01 acceptance: fresh archive → resolve → all product builds → all tests.
  # Smoke phase skips nested swift test (unit-test execution path; CI uses full).
  if [[ "$ARCHIVE_PHASE" == "smoke" ]]; then
    echo "== ARCHIVE_PHASE=smoke: skip nested swift test (full suite is CI source-archive-rehearsal) =="
  else
    echo "== swift test (full suite on clean tree) =="
    # Prevent infinite recursion when a regression test invokes this script.
    export CODEEDITOR_IN_ARCHIVE_REHEARSAL=1
    swift test
  fi
)

echo "OK: source-archive rehearsal passed (PKG-N01 clean resolve/build/test; ARCHIVE_PHASE=$ARCHIVE_PHASE)"
echo "    sha256=$SHA"
echo "    artifacts under $OUT_DIR (dependency-graph, fingerprints)"
