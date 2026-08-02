#!/usr/bin/env bash
# Maintainer tool: regenerate committed Tree-sitter C sources under
# Packages/CodeEditorGrammars/Sources/<lang>/ from upstream pins.
#
# Prerequisites: git, network access.
# Usage (from repo root):
#   ./scripts/update-grammars.sh
#
# Catalog: scripts/grammars.tsv
#   name|c_symbol|url|commit_sha|sha256_parser_c
# Queries (.scm) live under Sources/CodeEditorLanguages/Resources/ — not here.
# After running, commit Packages/CodeEditorGrammars and updated pin checksums.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="${TMPDIR:-/tmp}/codeeditorview-grammars"
mkdir -p "$TMP" Packages/CodeEditorGrammars/Sources

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

# Upstream monorepos often use #include "../../common/…" from src/; after flatten, map to local common/.
rewrite_relative_common_includes() {
  local dest="$1"
  local f tmp
  for f in "$dest"/*.c "$dest"/*.cc "$dest"/*.cpp "$dest"/*.h; do
    [[ -f "$f" ]] || continue
    if grep -q 'common/' "$f" 2>/dev/null; then
      tmp="$(mktemp)"
      sed -e 's|#include "../../../common/|#include "common/|g' \
          -e 's|#include "../../common/|#include "common/|g' \
          -e 's|#include "../common/|#include "common/|g' \
          "$f" >"$tmp"
      mv "$tmp" "$f"
    fi
  done
}

fetch_one() {
  local name="$1" c_symbol="$2" url="$3" pin="$4"
  local dest="Packages/CodeEditorGrammars/Sources/$name"
  mkdir -p "$dest"
  local clone="$TMP/$name"
  local is_sha=0
  if [[ "$pin" =~ ^[0-9a-fA-F]{40}$ ]]; then
    is_sha=1
  fi

  if [[ ! -d "$clone/.git" ]]; then
    echo "cloning $name ($pin)…"
    if [[ "$is_sha" -eq 1 ]]; then
      # Immutable pin: shallow fetch of the exact commit when possible.
      git clone --filter=blob:none --no-checkout "$url" "$clone" 2>/dev/null \
        || git clone "$url" "$clone"
      git -C "$clone" fetch --depth 1 origin "$pin" 2>/dev/null \
        || git -C "$clone" fetch origin "$pin" 2>/dev/null \
        || true
      git -C "$clone" checkout -q "$pin" 2>/dev/null \
        || git -C "$clone" checkout -q FETCH_HEAD 2>/dev/null \
        || git -C "$clone" checkout -q "$(git -C "$clone" rev-parse HEAD)"
    else
      git clone --depth 1 --branch "$pin" "$url" "$clone" 2>/dev/null \
        || git clone --depth 1 "$url" "$clone"
    fi
  else
    if [[ "$is_sha" -eq 1 ]]; then
      if ! git -C "$clone" cat-file -e "${pin}^{commit}" 2>/dev/null; then
        git -C "$clone" fetch --depth 1 origin "$pin" 2>/dev/null \
          || git -C "$clone" fetch origin "$pin" 2>/dev/null \
          || true
      fi
      git -C "$clone" checkout -q "$pin" 2>/dev/null \
        || git -C "$clone" checkout -q FETCH_HEAD 2>/dev/null \
        || true
    else
      git -C "$clone" fetch --depth 1 origin "$pin" 2>/dev/null || true
      git -C "$clone" checkout -q FETCH_HEAD 2>/dev/null \
        || git -C "$clone" checkout -q "$pin" 2>/dev/null \
        || true
    fi
  fi

  if [[ "$is_sha" -eq 1 ]]; then
    local head
    head="$(git -C "$clone" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$head" && "$head" != "$pin" ]]; then
      echo "warning: $name HEAD=$head expected pin=$pin" >&2
    fi
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

  # Copy sibling headers referenced by scanners (e.g. haskell's unicode.h).
  # Do not copy tree_sitter/ here — handled by copy_tree_sitter_headers.
  for f in "$srcdir"/*.h "$srcdir"/*.hpp "$srcdir"/*.inc; do
    [[ -f "$f" ]] || continue
    cp "$f" "$dest/"
  done

  copy_tree_sitter_headers "$srcdir" "$dest"
  # Fallback: any previously populated tree_sitter from another language.
  if [[ ! -f "$dest/tree_sitter/parser.h" ]]; then
    local sibling
    for sibling in Packages/CodeEditorGrammars/Sources/*/tree_sitter/parser.h; do
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
  rewrite_relative_common_includes "$dest"

  local stem
  stem="$(header_basename "$name")"
  write_language_header "$dest" "$stem" "$c_symbol"

  echo "updated $name → $dest (${c_symbol})"
}

failures=0
while IFS='|' read -r name c_symbol url pin checksum; do
  [[ -z "${name:-}" || "$name" =~ ^# ]] && continue
  # pin = commit SHA (preferred) or legacy branch/tag name
  if ! fetch_one "$name" "$c_symbol" "$url" "$pin"; then
    failures=$((failures + 1))
  fi
done < "$(dirname "$0")/grammars.tsv"

if [[ "$failures" -gt 0 ]]; then
  echo "Done with $failures failure(s). Fix grammars.tsv / network and re-run." >&2
  exit 1
fi

echo
echo "Done. Sources written to Packages/CodeEditorGrammars/Sources/ (committed artifacts)."
echo "Next: ./scripts/verify-grammars.sh && git add Packages/CodeEditorGrammars"
echo "Build language packs with:  swift build --product CodeEditorLanguages"
