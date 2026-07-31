#!/usr/bin/env bash
# Populate Grammars/ from upstream tree-sitter grammar repos (not checked into git).
#
# Prerequisites: git, network access.
# Usage (from repo root or anywhere):
#   ./scripts/update-grammars.sh
#
# Catalog: scripts/grammars.tsv  (name|c_symbol|url|ref)
# Queries (.scm) live under Sources/CodeEditorLanguages/Resources/ — not here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="${TMPDIR:-/tmp}/codeeditorview-grammars"
mkdir -p "$TMP" Grammars/src

header_basename() {
  # Directory name → public header stem (c-sharp → c_sharp, go-mod → go_mod).
  echo "$1" | tr '-' '_'
}

write_language_header() {
  local dest_dir="$1" header_stem="$2" c_symbol="$3"
  local guard
  guard="$(printf 'TREE_SITTER_%s_H_' "$header_stem" | tr '[:lower:]' '[:upper:]')"
  mkdir -p "$dest_dir/include"
  cat >"$dest_dir/include/${header_stem}.h" <<EOF
#ifndef ${guard}
#define ${guard}
typedef struct TSLanguage TSLanguage;
#ifdef __cplusplus
extern "C" {
#endif
const TSLanguage *${c_symbol}(void);
#ifdef __cplusplus
}
#endif
#endif
EOF
}

copy_tree_sitter_headers() {
  local srcdir="$1" dest="$2"
  mkdir -p "$dest/tree_sitter"
  if [[ -d "$srcdir/tree_sitter" ]]; then
    cp -R "$srcdir/tree_sitter/." "$dest/tree_sitter/"
    return 0
  fi
  # Some grammars only ship parser.h next to parser.c historically.
  if [[ -f "$srcdir/tree_sitter/parser.h" ]]; then
    cp "$srcdir/tree_sitter/parser.h" "$dest/tree_sitter/"
  fi
}

copy_common_if_needed() {
  local clone="$1" name="$2" dest="$3"
  # Languages whose scanner.c includes "common/scanner.h".
  case "$name" in
    typescript|tsx)
      if [[ -d "$clone/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/common/." "$dest/common/"
      fi
      ;;
    php)
      if [[ -d "$clone/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/common/." "$dest/common/"
      elif [[ -d "$clone/php/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/php/common/." "$dest/common/"
      fi
      ;;
    ocaml)
      if [[ -d "$clone/grammars/ocaml/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/grammars/ocaml/common/." "$dest/common/"
      elif [[ -d "$clone/ocaml/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/ocaml/common/." "$dest/common/"
      elif [[ -d "$clone/common" ]]; then
        mkdir -p "$dest/common"
        cp -R "$clone/common/." "$dest/common/"
      fi
      ;;
  esac
}

fetch_one() {
  local name="$1" c_symbol="$2" url="$3" ref="$4"
  local dest="Grammars/src/$name"
  mkdir -p "$dest"
  local clone="$TMP/$name"
  if [[ ! -d "$clone/.git" ]]; then
    echo "cloning $name ($ref)…"
    git clone --depth 1 --branch "$ref" "$url" "$clone" 2>/dev/null \
      || git clone --depth 1 "$url" "$clone"
  else
    # Reuse cache; optional refresh of the tracked ref.
    git -C "$clone" fetch --depth 1 origin "$ref" 2>/dev/null || true
    git -C "$clone" checkout -q FETCH_HEAD 2>/dev/null \
      || git -C "$clone" checkout -q "$ref" 2>/dev/null \
      || true
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
    echo "error: no parser.c for $name (looked in $srcdir)" >&2
    return 1
  fi

  # Clean previous generated sources for this language (keep dest dir).
  rm -rf "$dest"
  mkdir -p "$dest"

  # Copy all C/C++ compilation units Package.swift may list (parser, scanner, schema.*, …).
  local f
  for f in "$srcdir"/*.c "$srcdir"/*.cc "$srcdir"/*.cpp; do
    [[ -f "$f" ]] || continue
    cp "$f" "$dest/"
  done
  if [[ ! -f "$dest/parser.c" ]]; then
    echo "error: parser.c missing after copy for $name" >&2
    return 1
  fi

  copy_tree_sitter_headers "$srcdir" "$dest"
  # Fallback: any previously populated tree_sitter from another language.
  if [[ ! -f "$dest/tree_sitter/parser.h" ]]; then
    local sibling
    for sibling in Grammars/src/*/tree_sitter/parser.h; do
      if [[ -f "$sibling" ]]; then
        mkdir -p "$dest/tree_sitter"
        cp -R "$(dirname "$sibling")/." "$dest/tree_sitter/"
        break
      fi
    done
  fi
  if [[ ! -f "$dest/tree_sitter/parser.h" ]]; then
    echo "error: no tree_sitter/parser.h for $name" >&2
    return 1
  fi

  copy_common_if_needed "$clone" "$name" "$dest"

  local stem
  stem="$(header_basename "$name")"
  write_language_header "$dest" "$stem" "$c_symbol"

  echo "updated $name → $dest (${c_symbol})"
}

failures=0
while IFS='|' read -r name c_symbol url ref; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  if ! fetch_one "$name" "$c_symbol" "$url" "$ref"; then
    failures=$((failures + 1))
  fi
done < "$(dirname "$0")/grammars.tsv"

if [[ "$failures" -gt 0 ]]; then
  echo "Done with $failures failure(s). Fix grammars.tsv / network and re-run." >&2
  exit 1
fi

echo
echo "Done. Grammars/ is ready (gitignored — do not commit)."
echo "Build language packs with:  swift build"
echo "If Package.swift source lists drift, compare Grammars/src/*/ against targets."
