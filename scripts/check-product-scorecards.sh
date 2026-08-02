#!/usr/bin/env bash
# REL-N02 — product scorecards cannot pass on authored status alone.
# Requires CI-generated evidence (scorecard-evidence.json + generation block).
# - status "pass" requires existing artifact + measurable evidence fields
# - residual must be non-empty when any dimension is fail/partial/unproven
# - RELEASE_CERTIFY=1 rejects any non-pass, any residual, any open P0/P1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SC="${SCORECARD_PATH:-$ROOT/Docs/Architecture/scorecards/products.toml}"
EVIDENCE="${SCORECARD_EVIDENCE:-$ROOT/Baselines/evidence/scorecard-evidence.json}"

if [[ ! -f "$SC" ]]; then
  echo "FAIL: missing $SC"
  exit 1
fi

# Prefer regenerated scorecards when GENERATE_SCORECARDS=1 (CI default path)
if [[ "${GENERATE_SCORECARDS:-0}" == "1" ]]; then
  ./scripts/generate-product-scorecards.sh
fi

if [[ ! -f "$EVIDENCE" ]]; then
  echo "FAIL: missing CI evidence $EVIDENCE — run ./scripts/generate-product-scorecards.sh"
  exit 1
fi

python3 - "$ROOT" "$SC" "${RELEASE_CERTIFY:-0}" "$EVIDENCE" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
path = Path(sys.argv[2])
release = sys.argv[3] == "1"
evidence_path = Path(sys.argv[4])
text = path.read_text(encoding="utf-8")

required_products = {
  "CodeEditorCore","CodeEditorDocuments","CodeEditorCommands","CodeEditorWorkspace",
  "CodeEditorWorkbench","CodeEditorView","CodeEditorLanguageSupport","CodeEditorLanguageServices",
  "CodeEditorExtensionAPI","CodeEditorExtensionProtocol","CodeEditorExtensionGuest",
  "CodeEditorWasmEngine","CodeEditorWasmEngineWasmKit","CodeEditorExtensionWasmGuest",
  "CodeEditorExtensions","CodeEditorExtensionHost","CodeEditorLSP","CodeEditorDAP",
  "CodeEditorSearch","CodeEditorTasks","CodeEditorTerminal","CodeEditorSourceControl",
  "CodeEditorTreeSitter","CodeEditorLanguageSwift","CodeEditorLanguageJSON","CodeEditorLanguages",
  "CodeEditorTerminalGhostty",
  "codeeditor-extension",
  "ConformanceExtensionGuest",
}
dims = ["api","correctness","concurrency","tests","platform","operations","docs"]
allowed_status = {"pass","partial","fail","unproven"}

fail = 0

# Must be generated, not hand-authored status theater
if "generate-product-scorecards.sh" not in text and "[generation]" not in text:
    print("FAIL: scorecards missing [generation] / generator marker (must be CI-generated)")
    fail = 1
if "AUTO-GENERATED" not in text and "generated_at" not in text:
    print("FAIL: scorecards must include generation metadata (generated_at)")
    fail = 1

try:
    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
except Exception as e:
    print(f"FAIL: cannot parse evidence {evidence_path}: {e}")
    sys.exit(1)

for key in ("commit", "generated_at", "run_id", "artifacts", "platform"):
    if key not in evidence:
        print(f"FAIL: scorecard-evidence.json missing {key}")
        fail = 1

# Evidence artifacts must exist
arts = evidence.get("artifacts") or {}
for name, rel in arts.items():
    p = root / rel
    if not p.is_file():
        print(f"FAIL: evidence artifact missing ({name}): {rel}")
        fail = 1

# Platform job IDs required in evidence
plat = evidence.get("platform") or {}
if "macos15" not in plat:
    print("FAIL: evidence.platform.macos15 job id required")
    fail = 1

# Test counts required (may be 0 only if unproven and not release)
if "tests" not in evidence:
    print("FAIL: evidence.tests count required")
    fail = 1

cert_m = re.search(r'^certification\s*=\s*"([^"]+)"', text, re.M)
certification = cert_m.group(1) if cert_m else "unknown"
if certification in ("phase-16-rc", "stable", "rc") and not release:
    release = True

products = re.findall(r'\[\[product\]\](.*?)(?=\[\[product\]\]|\Z)', text, re.S)
found = set()

def parse_inline_table(block, key):
    m = re.search(rf'{re.escape(key)}\s*=\s*\{{([^}}]*)\}}', block, re.S)
    if m:
        body = m.group(1)
        sm = re.search(r'status\s*=\s*"([^"]+)"', body)
        am = re.search(r'artifact\s*=\s*"([^"]+)"', body)
        em = re.search(r'evidence\s*=\s*"([^"]+)"', body)
        extras = {}
        for ek in ("tests", "skipped", "count", "macos15", "ios18", "swift6_errors", "tsan_failures", "fault_suite", "symbolgraph"):
            xm = re.search(rf'{ek}\s*=\s*(?:"([^"]+)"|(\d+))', body)
            if xm:
                extras[ek] = xm.group(1) if xm.group(1) is not None else int(xm.group(2))
        return (sm.group(1) if sm else None, am.group(1) if am else (em.group(1) if em else None), extras)
    m2 = re.search(rf'{re.escape(key)}\s*=\s*"(pass|partial|fail|unproven)"', block)
    if m2:
        return (m2.group(1), None, {})
    return (None, None, {})

for block in products:
    name_m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if not name_m:
        print("FAIL: product block missing name")
        fail = 1
        continue
    name = name_m.group(1)
    found.add(name)

    # commit field required (CI-generated evidence)
    if not re.search(r'commit\s*=\s*"[0-9a-f]{7,40}"', block):
        print(f"FAIL: {name} missing commit SHA (CI-generated evidence required)")
        fail = 1

    dim_status = {}
    for d in dims:
        st, art, extras = parse_inline_table(block, d)
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
        if st == "pass":
            p = root / art
            if not p.is_file():
                print(f"FAIL: {name}.{d} status=pass but artifact missing: {art}")
                fail = 1
            if art.endswith(".md") and "evidence" not in art and "Baselines/" not in art:
                print(f"FAIL: {name}.{d} pass artifact must be measurable evidence, not prose: {art}")
                fail = 1
            # pass on correctness/tests requires numeric test evidence
            if d in ("correctness", "tests"):
                if "tests" not in extras and "count" not in extras:
                    print(f"FAIL: {name}.{d}=pass requires tests/count evidence field")
                    fail = 1
            if d == "platform":
                if "macos15" not in extras and "ios18" not in extras:
                    print(f"FAIL: {name}.platform=pass requires macos15/ios18 job IDs")
                    fail = 1
        else:
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
        print(f"FAIL: {name} has fail/partial/unproven dimensions but residual = []")
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
print(f"OK:   {len(found)} product scorecards valid ({mode}; certification={certification}; evidence-linked)")
PY
