#!/usr/bin/env bash
# Generate scripts/grammar-inventory.json from scripts/grammars.tsv (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TSV="scripts/grammars.tsv"
OUT="scripts/grammar-inventory.json"

# Best-effort SPDX map for known upstreams
license_for() {
  case "$1" in
    tree-sitter/*|tree-sitter-grammars/*) echo "MIT" ;;
    alex-pinkus/tree-sitter-swift) echo "MIT" ;;
    fwcd/tree-sitter-kotlin) echo "MIT" ;;
    *) echo "UNKNOWN" ;;
  esac
}

python3 - "$TSV" "$OUT" <<'PY'
import json, sys, re
from pathlib import Path
tsv, out = Path(sys.argv[1]), Path(sys.argv[2])
rows = []
for line in tsv.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("|")
    if len(parts) < 5:
        continue
    name, c_symbol, url, commit, sha = parts[0], parts[1], parts[2], parts[3], parts[4]
    m = re.search(r"github\.com/([^/]+/[^/]+)", url)
    repo = m.group(1).removesuffix(".git") if m else ""
    lic = "MIT"  # most tree-sitter grammars; review UNKNOWN cases in inventory
    if "UNKNOWN" in repo:
        lic = "UNKNOWN"
    rows.append({
        "name": name,
        "c_symbol": c_symbol,
        "repository_url": url,
        "repository": repo,
        "commit": commit,
        "parser_c_sha256": sha,
        "license": lic,
        "query_bundle": f"Sources/CodeEditorLanguages/Resources/tree-sitter-{name.replace('_','-')}",
    })
# Fix known licenses
KNOWN = {
    "tree-sitter/tree-sitter-json": "MIT",
    "alex-pinkus/tree-sitter-swift": "MIT",
    "tree-sitter/tree-sitter-c": "MIT",
}
for r in rows:
    if r["repository"] in KNOWN:
        r["license"] = KNOWN[r["repository"]]

doc = {
    "schema_version": 1,
    "description": "Hermetic grammar inventory for CodeEditorView language packs",
    "grammars": rows,
}
out.write_text(json.dumps(doc, indent=2) + "\n")
print(f"Wrote {out} ({len(rows)} grammars)")
PY
