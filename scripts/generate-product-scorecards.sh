#!/usr/bin/env bash
# REL-N02 — generate product scorecards from CI/local evidence (not hand-authored status).
# Writes:
#   Docs/Architecture/scorecards/products.toml
#   Baselines/evidence/scorecard-evidence.json
#   Baselines/evidence/scorecard-residuals.json
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT_TOML="${SCORECARD_PATH:-$ROOT/Docs/Architecture/scorecards/products.toml}"
EVIDENCE_DIR="${SCORECARD_EVIDENCE_DIR:-$ROOT/Baselines/evidence}"
mkdir -p "$(dirname "$OUT_TOML")" "$EVIDENCE_DIR"

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
TOOLCHAIN="$(swift --version 2>/dev/null | head -1 | tr -d '\r' || echo "unknown")"
GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}"
JOB_MACOS="${CI_JOB_MACOS:-${GITHUB_JOB:-local/macos}}"
JOB_IOS="${CI_JOB_IOS:-local/ios-not-run}"
TEST_SUITE_VERSION="${TEST_SUITE_VERSION:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}"

# Optional: counts from prior swift test log (when present)
SWIFT_TEST_LOG="${SWIFT_TEST_LOG:-$EVIDENCE_DIR/swift-test.log}"
TEST_TOTAL=0
TEST_SKIPPED=0
if [[ -f "$SWIFT_TEST_LOG" ]]; then
  # swift-testing: "Test run with N tests in M suites passed after ..."
  if grep -Eo 'Test run with [0-9]+ tests' "$SWIFT_TEST_LOG" >/dev/null 2>&1; then
    TEST_TOTAL="$(grep -Eo 'Test run with [0-9]+ tests' "$SWIFT_TEST_LOG" | tail -1 | grep -Eo '[0-9]+' | head -1 || echo 0)"
  fi
  if grep -Eoi 'skipped|XCTSkip' "$SWIFT_TEST_LOG" >/dev/null 2>&1; then
    TEST_SKIPPED="$(grep -Eoi 'skipped|XCTSkip' "$SWIFT_TEST_LOG" | wc -l | tr -d ' ')"
  fi
fi

FINDINGS="$ROOT/Docs/Architecture/AUDIT-2026-08-02-FINDINGS.json"
DEFECTS="$ROOT/Docs/Architecture/defects.json"

python3 - "$ROOT" "$OUT_TOML" "$EVIDENCE_DIR" "$COMMIT" "$TOOLCHAIN" "$GENERATED_AT" "$RUN_ID" \
  "$JOB_MACOS" "$JOB_IOS" "$TEST_SUITE_VERSION" "$TEST_TOTAL" "$TEST_SKIPPED" "$FINDINGS" "$DEFECTS" <<'PY'
import json, os, re, sys
from pathlib import Path

(
    root_s, out_toml, evidence_dir, commit, toolchain, generated_at, run_id,
    job_macos, job_ios, test_suite_version, test_total_s, test_skipped_s,
    findings_path, defects_path,
) = sys.argv[1:]
root = Path(root_s)
evidence = Path(evidence_dir)
test_total = int(test_total_s or 0)
test_skipped = int(test_skipped_s or 0)

PRODUCTS = [
    "CodeEditorCore", "CodeEditorDocuments", "CodeEditorCommands", "CodeEditorWorkspace",
    "CodeEditorWorkbench", "CodeEditorView", "CodeEditorLanguageSupport", "CodeEditorLanguageServices",
    "CodeEditorExtensionAPI", "CodeEditorExtensionProtocol", "CodeEditorExtensionGuest",
    "CodeEditorWasmEngine", "CodeEditorWasmEngineWasmKit", "CodeEditorExtensionWasmGuest",
    "CodeEditorExtensions", "CodeEditorExtensionHost", "CodeEditorLSP", "CodeEditorDAP",
    "CodeEditorSearch", "CodeEditorTasks", "CodeEditorTerminal", "CodeEditorSourceControl",
    "CodeEditorTreeSitter", "CodeEditorLanguageSwift", "CodeEditorLanguageJSON", "CodeEditorLanguages",
    "CodeEditorTerminalGhostty", "codeeditor-extension", "ConformanceExtensionGuest",
]

# Map findings phase names → products (coarse residual linkage)
PHASE_RESIDUAL = {
    0: ["PKG-N01", "REL-N01", "REL-N02", "REL-N03", "REL-N04", "REL-N05", "REL-N06", "REL-N07", "REL-N08"],
    1: ["DOC residual open — phase 1"],
    2: ["CORE residual open — phase 2"],
    3: ["CMD/UI residual open — phase 3"],
    4: ["WSP residual open — phase 4"],
    5: ["SEARCH/TASKS/SCM residual open — phase 5"],
    6: ["LANG/LSP residual open — phase 6"],
    7: ["DAP residual open — phase 7"],
    8: ["TERM residual open — phase 8"],
    9: ["EXT residual open — phase 9"],
    10: ["WB residual open — phase 10"],
}

PRODUCT_PHASE = {
    "CodeEditorCore": 2,
    "CodeEditorDocuments": 1,
    "CodeEditorCommands": 3,
    "CodeEditorWorkspace": 4,
    "CodeEditorWorkbench": 10,
    "CodeEditorView": 3,
    "CodeEditorLanguageSupport": 6,
    "CodeEditorLanguageServices": 6,
    "CodeEditorExtensionAPI": 9,
    "CodeEditorExtensionProtocol": 9,
    "CodeEditorExtensionGuest": 9,
    "CodeEditorWasmEngine": 9,
    "CodeEditorWasmEngineWasmKit": 9,
    "CodeEditorExtensionWasmGuest": 9,
    "CodeEditorExtensions": 9,
    "CodeEditorExtensionHost": 9,
    "CodeEditorLSP": 6,
    "CodeEditorDAP": 7,
    "CodeEditorSearch": 5,
    "CodeEditorTasks": 5,
    "CodeEditorTerminal": 8,
    "CodeEditorSourceControl": 5,
    "CodeEditorTreeSitter": 6,
    "CodeEditorLanguageSwift": 6,
    "CodeEditorLanguageJSON": 6,
    "CodeEditorLanguages": 6,
    "CodeEditorTerminalGhostty": 8,
    "codeeditor-extension": 9,
    "ConformanceExtensionGuest": 9,
}

open_findings = []
if Path(findings_path).is_file():
    try:
        fj = json.loads(Path(findings_path).read_text(encoding="utf-8"))
        for f in fj.get("findings") or []:
            st = f.get("status")
            if st in ("open", "in_progress"):
                open_findings.append(f)
    except Exception as e:
        print(f"WARN: findings parse: {e}", file=sys.stderr)

open_p0 = sum(1 for f in open_findings if str(f.get("severity", "")).startswith("P0"))
open_p1 = sum(1 for f in open_findings if str(f.get("severity", "")).startswith("P1"))

# Per-product residual IDs from open findings that mention product or phase
def residuals_for(product: str):
    phase = PRODUCT_PHASE.get(product, 0)
    ids = []
    for f in open_findings:
        fid = f.get("id") or ""
        fphase = f.get("phase")
        title = (f.get("title") or "") + " " + (f.get("notes") or "")
        if fphase == phase or product.replace("CodeEditor", "") in title or product in title:
            ids.append(fid)
    if not ids:
        ids = list(PHASE_RESIDUAL.get(phase, [f"residual open — phase {phase}"]))
    # Cap for readability
    return ids[:12] if ids else [f"residual open — {product}"]

def artifact_exists(rel: str) -> bool:
    return (root / rel).is_file()

def dim(status: str, artifact: str, **extra):
    d = {"status": status, "artifact": artifact}
    d.update(extra)
    return d

# Evidence files generated this run
correctness_art = evidence / "scorecard-correctness.json"
platform_art = evidence / "scorecard-platform.json"
tests_art = evidence / "scorecard-tests.json"
concurrency_art = evidence / "scorecard-concurrency.json"
ops_art = evidence / "scorecard-operations.json"
api_meta = evidence / "scorecard-api.json"

correctness_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "run_id": run_id,
    "open_findings": len(open_findings),
    "open_p0": open_p0,
    "open_p1": open_p1,
    "source": "AUDIT-2026-08-02-FINDINGS.json",
    "status": "fail" if open_findings else "pass",
}
tests_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "run_id": run_id,
    "tests": test_total,
    "skipped": test_skipped,
    "test_suite_version": test_suite_version,
    "log": "Baselines/evidence/swift-test.log" if (evidence / "swift-test.log").is_file() else None,
    "status": "unproven" if test_total == 0 else ("fail" if test_skipped > 0 else "partial"),
}
platform_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "run_id": run_id,
    "macos15": f"job/{job_macos}",
    "ios18": f"job/{job_ios}",
    "toolchain": toolchain,
    "status": "partial" if job_macos.startswith("local") else "pass",
}
concurrency_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "allowlist": "Baselines/unchecked-sendable-allowlist.txt",
    "swift6_errors": None,
    "tsan_failures": None,
    "status": "fail",
}
ops_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "fault_suite": "Docs/Architecture/defects.json",
    "status": "fail",
}
api_payload = {
    "schema_version": 1,
    "generated_at": generated_at,
    "commit": commit,
    "symbolgraph_dir": "Baselines/api/symbol-graphs",
    "digester_dir": "Baselines/api/digester",
    "status": "partial" if any((root / "Baselines/api").glob("*.public.txt")) else "fail",
}

for path, payload in [
    (correctness_art, correctness_payload),
    (tests_art, tests_payload),
    (platform_art, platform_payload),
    (concurrency_art, concurrency_payload),
    (ops_art, ops_payload),
    (api_meta, api_payload),
]:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

# Aggregate evidence index
index = {
    "schema_version": 1,
    "generated_at": generated_at,
    "generator": "scripts/generate-product-scorecards.sh",
    "commit": commit,
    "toolchain": toolchain,
    "run_id": run_id,
    "test_suite_version": test_suite_version,
    "tests": test_total,
    "skipped": test_skipped,
    "platform": {"macos15": f"job/{job_macos}", "ios18": f"job/{job_ios}"},
    "open_p0": open_p0,
    "open_p1": open_p1,
    "products": PRODUCTS,
    "artifacts": {
        "correctness": str(correctness_art.relative_to(root)),
        "tests": str(tests_art.relative_to(root)),
        "platform": str(platform_art.relative_to(root)),
        "concurrency": str(concurrency_art.relative_to(root)),
        "operations": str(ops_art.relative_to(root)),
        "api": str(api_meta.relative_to(root)),
    },
}
(evidence / "scorecard-evidence.json").write_text(
    json.dumps(index, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)

residuals_by_product = {}
lines = [
    "# AUTO-GENERATED by scripts/generate-product-scorecards.sh — do not hand-author pass/fail.",
    f"# generated_at = \"{generated_at}\"",
    f"# commit = \"{commit}\"",
    f"# run_id = \"{run_id}\"",
    f"# generator = \"scripts/generate-product-scorecards.sh\"",
    "schema_version = 3",
    'certification = "pre-alpha"',
    'program = "audit-2026-08-02-deep-remediation"',
    'source = "Baselines/evidence/scorecard-evidence.json"',
    "",
    "[generation]",
    f'generated_at = "{generated_at}"',
    f'commit = "{commit}"',
    f'toolchain = {json.dumps(toolchain)}',
    f'run_id = "{run_id}"',
    f'test_suite_version = "{test_suite_version}"',
    f"tests = {test_total}",
    f"skipped = {test_skipped}",
    f'evidence = "Baselines/evidence/scorecard-evidence.json"',
    f'macos15_job = "job/{job_macos}"',
    f'ios18_job = "job/{job_ios}"',
    "",
]

def fmt_dim(name, st, art, extras=None):
    parts = [f'status = "{st}"', f'artifact = "{art}"']
    if extras:
        for k, v in extras.items():
            if isinstance(v, str):
                parts.append(f'{k} = "{v}"')
            else:
                parts.append(f"{k} = {v}")
    return f"{name} = {{ " + ", ".join(parts) + " }"

for product in PRODUCTS:
    res = residuals_for(product)
    residuals_by_product[product] = res
    api_file = f"Baselines/api/{product}.public.txt"
    if product in ("codeeditor-extension", "ConformanceExtensionGuest"):
        api_file = "Baselines/evidence/scorecard-api.json"
    if not artifact_exists(api_file):
        api_file = "Baselines/evidence/scorecard-api.json"
    # Pre-alpha: dimensions are fail/unproven/partial with residual; never hand-authored pass without real green CI.
    api_st = "partial" if artifact_exists(api_file) else "fail"
    corr_st = "fail" if open_findings else "unproven"
    conc_st = "fail"
    tests_st = tests_payload["status"]
    plat_st = platform_payload["status"]
    ops_st = "fail"
    docs_st = "partial" if artifact_exists("README.md") else "fail"

    p0 = open_p0
    p1 = open_p1
    lines.append("[[product]]")
    lines.append(f'name = "{product}"')
    lines.append(f'commit = "{commit}"')
    lines.append('tier = "Pre-alpha"')
    lines.append(f"open_p0 = {p0}")
    lines.append(f"open_p1 = {p1}")
    lines.append(fmt_dim("api", api_st, api_file, {"symbolgraph": "Baselines/api/symbol-graphs"} if product.startswith("CodeEditor") else None))
    lines.append(fmt_dim(
        "correctness", corr_st, "Baselines/evidence/scorecard-correctness.json",
        {"tests": test_total, "skipped": test_skipped},
    ))
    lines.append(fmt_dim("concurrency", conc_st, "Baselines/evidence/scorecard-concurrency.json", {"swift6_errors": 0, "tsan_failures": 0}))
    lines.append(fmt_dim("tests", tests_st, "Baselines/evidence/scorecard-tests.json", {"count": test_total, "skipped": test_skipped}))
    lines.append(fmt_dim("platform", plat_st, "Baselines/evidence/scorecard-platform.json", {"macos15": f"job/{job_macos}", "ios18": f"job/{job_ios}"}))
    lines.append(fmt_dim("operations", ops_st, "Baselines/evidence/scorecard-operations.json", {"fault_suite": "Docs/Architecture/defects.json"}))
    lines.append(fmt_dim("docs", docs_st, "README.md"))
    res_lit = ", ".join(json.dumps(x) for x in res)
    lines.append(f"residual = [{res_lit}]")
    lines.append("")

Path(out_toml).write_text("\n".join(lines) + "\n", encoding="utf-8")
(evidence / "scorecard-residuals.json").write_text(
    json.dumps({"residuals_by_product": residuals_by_product, "generated_at": generated_at, "commit": commit}, indent=2)
    + "\n",
    encoding="utf-8",
)
print(f"OK: generated {out_toml} ({len(PRODUCTS)} products)")
print(f"OK: evidence {evidence / 'scorecard-evidence.json'}")
PY
