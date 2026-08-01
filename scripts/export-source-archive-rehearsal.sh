#!/usr/bin/env bash
# PKG-001 / CI-010: export a source archive into an empty directory and build.
# Hard-fails if clean-tree resolve/build does not succeed.
#
# Prefer committed tree (git archive HEAD). If Packages/CodeEditorGrammars is not
# yet in HEAD but is staged/present, use a worktree export so local validation
# works before the first commit of the package.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-$ROOT/Baselines/evidence}"
mkdir -p "$OUT_DIR"

STAGING="$(mktemp -d /tmp/codeeditor-archive-XXXXXX)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

ARCHIVE="$STAGING/source.tar.gz"
EXTRACT="$STAGING/extract"
mkdir -p "$EXTRACT"

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
  # Mirror a release source tree: tracked-like content without .git / build products.
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

echo "== resolve + build (empty tree) =="
(
  cd "$EXTRACT"
  rm -rf .build
  swift package resolve
  swift build --product CodeEditorCore
  swift build --product CodeEditorView
  swift build --product CodeEditorWorkbench
  swift build --product CodeEditorLanguageSwift
  swift build --product CodeEditorLanguageJSON
)

echo "OK: source-archive rehearsal passed"
echo "    sha256=$SHA"
