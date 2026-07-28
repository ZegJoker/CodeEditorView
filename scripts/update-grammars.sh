#!/usr/bin/env bash
# Refresh vendored tree-sitter C grammars under Grammars/src (multiplatform; no binary container).
# Query .scm files live separately under Sources/CodeEditorLanguages/Resources/tree-sitter-*.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="${TMPDIR:-/tmp}/codeeditorview-grammars"
mkdir -p "$TMP" Grammars/include/tree_sitter Grammars/src

fetch_one() {
  local name="$1" fn="$2" url="$3" ref="$4"
  local dest="Grammars/src/$name"
  mkdir -p "$dest"
  local clone="$TMP/$name"
  if [[ ! -d "$clone/.git" ]]; then
    git clone --depth 1 --branch "$ref" "$url" "$clone" 2>/dev/null \
      || git clone --depth 1 "$url" "$clone"
  fi

  local srcdir="$clone/src"
  case "$name" in
    typescript) srcdir="$clone/typescript/src" ;;
    tsx) srcdir="$clone/tsx/src" ;;
    markdown) srcdir="$clone/tree-sitter-markdown/src" ;;
    markdown-inline) srcdir="$clone/tree-sitter-markdown-inline/src" ;;
    ocaml)
      [[ -d "$clone/grammars/ocaml/src" ]] && srcdir="$clone/grammars/ocaml/src"
      [[ -d "$clone/ocaml/src" ]] && srcdir="$clone/ocaml/src"
      ;;
    php) [[ -d "$clone/php/src" ]] && srcdir="$clone/php/src" ;;
  esac

  if [[ ! -f "$srcdir/parser.c" ]]; then
    echo "error: no parser.c for $name" >&2
    return 1
  fi
  cp "$srcdir/parser.c" "$dest/"
  [[ -f "$srcdir/scanner.c" ]] && cp "$srcdir/scanner.c" "$dest/"
  [[ -f "$srcdir/scanner.cc" ]] && cp "$srcdir/scanner.cc" "$dest/"

  if [[ -d "$srcdir/tree_sitter" && ! -f Grammars/include/tree_sitter/parser.h ]]; then
    cp -R "$srcdir/tree_sitter/." Grammars/include/tree_sitter/
  fi
  echo "updated $name"
}

while IFS='|' read -r name fn url ref; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  fetch_one "$name" "$fn" "$url" "$ref"
done < "$(dirname "$0")/grammars.tsv"

echo "Done. Update Package.swift sources: if new files appear under Grammars/src."
