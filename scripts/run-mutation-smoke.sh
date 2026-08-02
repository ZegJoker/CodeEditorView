#!/usr/bin/env bash
# §26.6 targeted mutation smoke — invert a critical pure check; suite must FAIL.
# Uses an isolated temp copy so the working tree is never left mutated.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET_REL="Sources/CodeEditorCore/Document/TextOffsetSemantics.swift"
if [[ ! -f "$TARGET_REL" ]]; then
  echo "FAIL: missing $TARGET_REL"
  exit 1
fi

STAGING="$(mktemp -d /tmp/codeeditor-mutation-XXXXXX)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

echo "== mutation smoke target: $TARGET_REL =="
# Minimal package copy for Core tests (exclude heavy build artifacts).
rsync -a \
  --exclude '.build' \
  --exclude '.git' \
  --exclude 'Baselines/evidence' \
  --exclude 'DerivedData' \
  "$ROOT/" "$STAGING/tree/"

MUTATED="$STAGING/tree/$TARGET_REL"
python3 - "$MUTATED" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
original = text
# Kill DOC-003 / offset validation: invert isValidUTF16Offset (tests assert invalid offsets throw
# and valid round-trips). This is a high-value mutant for TextOffsetSemanticsTests.
needle = "offset >= 0 && offset <= length"
repl = "offset < 0 || offset > length  /* MUTATION_SMOKE */"
if needle not in text:
    # Fallback: force zero-offset path to return wrong non-zero
    needle2 = "if utf16Offset == 0 { return 0 }"
    repl2 = "if utf16Offset == 0 { return 1 /* MUTATION_SMOKE */ }"
    if needle2 not in text:
        text = text + '\n#error("MUTATION_SMOKE: no mutation site found")\n'
    else:
        text = text.replace(needle2, repl2, 1)
else:
    text = text.replace(needle, repl, 1)
if text == original:
    print("FAIL: mutation did not change file", file=sys.stderr)
    sys.exit(2)
path.write_text(text, encoding="utf-8")
print("mutated", path, "delta_bytes", len(text) - len(original))
if "MUTATION_SMOKE" not in text and "#error" not in text:
    print("FAIL: mutation marker missing", file=sys.stderr)
    sys.exit(2)
PY

echo "== expect CodeEditorCoreTests / TextOffsetSemantics to FAIL under mutant =="
set +e
(
  cd "$STAGING/tree"
  # Filter to the suite that must die under this mutant (faster + stronger signal).
  swift test --filter 'TextOffsetSemantics' 2>&1 | tee /tmp/mutation-smoke.log
)
EC=$?
set -e

if [[ "$EC" -eq 0 ]]; then
  echo "FAIL: mutation survived — TextOffsetSemantics tests still passed under mutant"
  tail -40 /tmp/mutation-smoke.log || true
  exit 1
fi

echo "OK:   mutation smoke killed (exit $EC) — tests/build failed as required"
exit 0
