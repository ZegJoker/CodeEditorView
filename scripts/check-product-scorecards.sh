#!/usr/bin/env bash
# Validate machine-readable product scorecards cover all public products and have no P0/P1 residuals.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SC="$ROOT/Docs/Architecture/scorecards/products.toml"
if [[ ! -f "$SC" ]]; then
  echo "FAIL: missing $SC"
  exit 1
fi
python3 - "$SC" <<'PY'
import sys, re
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# Parse simple TOML-ish sections [[product]]
products = re.findall(r'\[\[product\]\](.*?)(?=\[\[product\]\]|\Z)', text, re.S)
required_products = {
  "CodeEditorCore","CodeEditorDocuments","CodeEditorCommands","CodeEditorWorkspace",
  "CodeEditorWorkbench","CodeEditorView","CodeEditorLanguageSupport","CodeEditorLanguageServices",
  "CodeEditorExtensionAPI","CodeEditorExtensionProtocol","CodeEditorExtensionGuest",
  "CodeEditorWasmEngine","CodeEditorWasmEngineWasmKit","CodeEditorExtensionWasmGuest",
  "CodeEditorExtensions","CodeEditorExtensionHost","CodeEditorLSP","CodeEditorDAP",
  "CodeEditorSearch","CodeEditorTasks","CodeEditorTerminal","CodeEditorSourceControl",
  "CodeEditorTreeSitter","CodeEditorLanguageSwift","CodeEditorLanguageJSON","CodeEditorLanguages",
}
dims = ["api","correctness","concurrency","tests","platform","operations","docs"]
found = set()
fail = 0
for block in products:
    name_m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if not name_m:
        print("FAIL: product block missing name")
        fail = 1
        continue
    name = name_m.group(1)
    found.add(name)
    for d in dims:
        if not re.search(rf'{d}\s*=\s*"(pass|partial|fail)"', block):
            print(f"FAIL: {name} missing dimension {d}")
            fail = 1
        # evidence required
        if not re.search(rf'{d}_evidence\s*=\s*"[^"]+"', block):
            print(f"FAIL: {name} missing {d}_evidence")
            fail = 1
    # Zero residual policy: residual array must be empty
    for m in re.finditer(r'residual\s*=\s*\[(.*?)\]', block, re.S):
        body = m.group(1).strip()
        if body:
            print(f"FAIL: {name} residual list must be empty (got {body!r})")
            fail = 1
    if not re.search(r'residual\s*=\s*\[', block):
        print(f"FAIL: {name} missing residual = []")
        fail = 1
missing = sorted(required_products - found)
extra_ok = found - required_products
if missing:
    print("FAIL: missing products:", ", ".join(missing))
    fail = 1
if fail:
    sys.exit(1)
print(f"OK:   {len(found)} product scorecards valid (all residual arrays empty)")
PY
