#!/usr/bin/env bash
# Fail if scripts/grammars.tsv still uses mutable branch pins or missing SHAs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TSV="scripts/grammars.tsv"
fail=0
mutable=0
rows=0

is_full_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

is_mutable_ref() {
  case "$1" in
    main|master|HEAD|develop|trunk|gh-pages|with-generated-files|split_parser) return 0 ;;
    *) return 1 ;;
  esac
}

echo "== Grammar pin check ($TSV) =="

while IFS='|' read -r name c_symbol url pin checksum; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  rows=$((rows + 1))
  if [[ -z "${pin:-}" ]]; then
    echo "FAIL: $name missing pin column"
    fail=1
    continue
  fi
  if is_mutable_ref "$pin"; then
    echo "FAIL: $name pinned to mutable ref '$pin' (require full commit SHA)"
    fail=1
    mutable=$((mutable + 1))
    continue
  fi
  if ! is_full_sha "$pin"; then
    # Allow abbreviated only if STRICT wants full — Phase 1 requires 40-char.
    echo "FAIL: $name pin is not a 40-char commit SHA: $pin"
    fail=1
    continue
  fi
  if [[ -z "${url:-}" || ! "$url" =~ ^https?:// ]]; then
    echo "FAIL: $name has invalid url"
    fail=1
  fi
  echo "OK:   $name @ ${pin:0:12}"
done <"$TSV"

if [[ "$rows" -eq 0 ]]; then
  echo "FAIL: no grammar rows found"
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Grammar pin check FAILED ($mutable mutable ref(s))."
  echo "Run: ./scripts/record-grammar-pins.sh"
  exit 1
fi

echo
echo "All $rows grammar pins are immutable commit SHAs."
