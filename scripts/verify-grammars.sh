#!/usr/bin/env bash
# Hermetic grammar verification: pins + optional on-disk parser.c checksums (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== pins =="
./scripts/check-grammar-pins.sh

if [[ ! -f scripts/grammar-inventory.json ]]; then
  echo "Generating grammar-inventory.json…"
  ./scripts/generate-grammar-inventory.sh
fi

echo "== inventory =="
python3 - <<'PY'
import json
from pathlib import Path
doc = json.loads(Path("scripts/grammar-inventory.json").read_text())
gs = doc.get("grammars") or []
assert gs, "empty inventory"
ids = [g["name"] for g in gs]
assert len(ids) == len(set(ids)), "duplicate grammar names in inventory"
symbols = [g["c_symbol"] for g in gs]
assert len(symbols) == len(set(symbols)), "duplicate c_symbol in inventory"
print(f"OK:   inventory {len(gs)} grammars, unique names/symbols")
PY

if [[ ! -d Grammars/src ]]; then
  echo "SKIP: Grammars/src not present (run update-grammars.sh to verify checksums)"
  exit 0
fi

echo "== parser.c checksums =="
fail=0
while IFS='|' read -r name c_symbol url commit sha; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  f="Grammars/src/$name/parser.c"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: missing $f"
    fail=1
    continue
  fi
  if command -v shasum >/dev/null; then
    actual=$(shasum -a 256 "$f" | awk '{print $1}')
  else
    actual=$(sha256sum "$f" | awk '{print $1}')
  fi
  if [[ "$actual" != "$sha" ]]; then
    echo "FAIL: $name parser.c checksum mismatch"
    echo "  expected $sha"
    echo "  actual   $actual"
    fail=1
  else
    echo "OK:   $name"
  fi
done < scripts/grammars.tsv

if [[ "$fail" -ne 0 ]]; then
  echo "verify-grammars FAILED"
  exit 1
fi
echo "verify-grammars: all checks passed"
