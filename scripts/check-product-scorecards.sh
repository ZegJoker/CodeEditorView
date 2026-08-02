#!/usr/bin/env bash
# REL-N02 — product scorecards cannot pass on authored status alone.
# Validates evidence-linked scorecards for all public products.
# - status "pass" requires an existing artifact path
# - residual must be non-empty when any dimension is fail/partial (honesty)
# - RELEASE_CERTIFY=1 rejects any non-pass, any residual, any open P0/P1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SC="${SCORECARD_PATH:-$ROOT/Docs/Architecture/scorecards/products.toml}"
if [[ ! -f "$SC" ]]; then
  echo "FAIL: missing $SC"
  exit 1
fi

python3 - "$ROOT" "$SC" "${RELEASE_CERTIFY:-0}" <<'PY'
import os, re, sys, json
from pathlib import Path

root = Path(sys.argv[1])
path = Path(sys.argv[2])
release = sys.argv[3] == "1"
text = path.read_text(encoding="utf-8")

required_products = {
  "CodeEditorCore","CodeEditorDocuments","CodeEditorCommands","CodeEditorWorkspace",
  "CodeEditorWorkbench","CodeEditorView","CodeEditorLanguageSupport","CodeEditorLanguageServices",
  "CodeEditorExtensionAPI","CodeEditorExtensionProtocol","CodeEditorExtensionGuest",
  "CodeEditorWasmEngine","CodeEditorWasmEngineWasmKit","CodeEditorExtensionWasmGuest",
  "CodeEditorExtensions","CodeEditorExtensionHost","CodeEditorLSP","CodeEditorDAP",
  "CodeEditorSearch","CodeEditorTasks","CodeEditorTerminal","CodeEditorSourceControl",
  "CodeEditorTreeSitter","CodeEditorLanguageSwift","CodeEditorLanguageJSON","CodeEditorLanguages",
  # REL-N02 omitted products
  "CodeEditorTerminalGhostty",
  "codeeditor-extension",
  "ConformanceExtensionGuest",
}
dims = ["api","correctness","concurrency","tests","platform","operations","docs"]
allowed_status = {"pass","partial","fail","unproven"}

# certification top-level
cert_m = re.search(r'^certification\s*=\s*"([^"]+)"', text, re.M)
certification = cert_m.group(1) if cert_m else "unknown"
if certification in ("phase-16-rc", "stable", "rc") and not release:
    # Claiming RC/stable in the file forces release-certify rules.
    release = True

products = re.findall(r'\[\[product\]\](.*?)(?=\[\[product\]\]|\Z)', text, re.S)
found = set()
fail = 0

def parse_inline_table(block, key):
    # dim = { status = "fail", artifact = "path" }  OR legacy dim = "fail"
    m = re.search(rf'{re.escape(key)}\s*=\s*\{{([^}}]*)\}}', block, re.S)
    if m:
        body = m.group(1)
        sm = re.search(r'status\s*=\s*"([^"]+)"', body)
        am = re.search(r'artifact\s*=\s*"([^"]+)"', body)
        em = re.search(r'evidence\s*=\s*"([^"]+)"', body)
        return (sm.group(1) if sm else None, am.group(1) if am else (em.group(1) if em else None))
    m2 = re.search(rf'{re.escape(key)}\s*=\s*"(pass|partial|fail|unproven)"', block)
    if m2:
        ev = re.search(rf'{re.escape(key)}_evidence\s*=\s*"([^"]+)"', block)
        art = re.search(rf'{re.escape(key)}_artifact\s*=\s*"([^"]+)"', block)
        return (m2.group(1), (art.group(1) if art else (ev.group(1) if ev else None)))
    return (None, None)

for block in products:
    name_m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if not name_m:
        print("FAIL: product block missing name")
        fail = 1
        continue
    name = name_m.group(1)
    found.add(name)

    dim_status = {}
    for d in dims:
        st, art = parse_inline_table(block, d)
        if st is None:
            print(f"FAIL: {name} missing dimension {d}")
            fail = 1
            continue
        if st not in allowed_status:
            print(f"FAIL: {name}.{d} invalid status {st!r}")
            fail = 1
            continue
        dim_status[d] = st
        if art is None or not str(art).strip():
            print(f"FAIL: {name}.{d} missing artifact/evidence path")
            fail = 1
            continue
        # pass requires a real filesystem artifact (not prose-only)
        if st == "pass":
            p = root / art
            if not p.is_file():
                print(f"FAIL: {name}.{d} status=pass but artifact missing: {art}")
                fail = 1
            # reject pure prose claim paths that are just markdown notes without measurements
            if art.endswith(".md") and "evidence" not in art and "Baselines/" not in art:
                print(f"FAIL: {name}.{d} pass artifact must be measurable evidence, not prose: {art}")
                fail = 1
        else:
            # non-pass still needs a non-empty evidence pointer (may be docs path)
            if len(str(art).strip()) < 3:
                print(f"FAIL: {name}.{d} evidence too short")
                fail = 1

    residual_m = re.search(r'residual\s*=\s*\[(.*?)\]', block, re.S)
    if not residual_m:
        print(f"FAIL: {name} missing residual = []")
        fail = 1
        residual_items = []
    else:
        body = residual_m.group(1).strip()
        residual_items = [x.strip().strip('"').strip("'") for x in body.split(",") if x.strip()]

    any_bad = any(s in ("fail", "partial", "unproven") for s in dim_status.values())
    if any_bad and not residual_items:
        print(f"FAIL: {name} has fail/partial/unproven dimensions but residual = [] (cannot claim zero residual)")
        fail = 1
    if not any_bad and residual_items and release:
        print(f"FAIL: {name} release residual must be empty when all dimensions pass")
        fail = 1

    if release:
        for d, st in dim_status.items():
            if st != "pass":
                print(f"FAIL: RELEASE_CERTIFY {name}.{d}={st} (must be pass)")
                fail = 1
        if residual_items:
            print(f"FAIL: RELEASE_CERTIFY {name} residual must be empty, got {residual_items}")
            fail = 1
        for key in ("open_p0", "open_p1"):
            m = re.search(rf'{key}\s*=\s*(\d+)', block)
            if m and int(m.group(1)) != 0:
                print(f"FAIL: RELEASE_CERTIFY {name}.{key}={m.group(1)} must be 0")
                fail = 1

missing = sorted(required_products - found)
if missing:
    print("FAIL: missing products:", ", ".join(missing))
    fail = 1

if fail:
    sys.exit(1)
mode = "RELEASE_CERTIFY" if release else "pre-alpha honesty"
print(f"OK:   {len(found)} product scorecards valid ({mode}; certification={certification})")
PY
