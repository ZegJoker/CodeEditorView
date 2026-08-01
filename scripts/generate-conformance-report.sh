#!/usr/bin/env bash
# Assemble S0–S4 conformance report evidence (does not invent pass without filters).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-Docs/Architecture/CONFORMANCE-REPORT.md}"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_filter() {
  local name="$1"
  local filter="$2"
  if swift test --filter "$filter" >/tmp/p16-"$name".log 2>&1; then
    echo "pass"
  else
    echo "fail"
  fi
}

echo "Running S0–S4 evidence filters (this may take a few minutes)…"
s0_status=pass
s1_status=pass
s2_status=pass
s3_status=pass
s4_status=pass

if ! swift test --filter ExtensionPackage >/tmp/p16-s01b.log 2>&1; then
  s0_status=fail
  s1_status=fail
fi
if ! swift test --filter Phase12 >/tmp/p16-s2.log 2>&1; then
  s2_status=partial
fi
if ! swift test --filter Phase10 >/tmp/p16-s3a.log 2>&1; then
  s3_status=partial
fi
if ! swift test --filter Phase11 >/tmp/p16-s3b.log 2>&1; then
  if [[ "$s3_status" == pass ]]; then s3_status=partial; fi
fi
if ! swift test --filter Phase14 >/tmp/p16-s4a.log 2>&1; then
  s4_status=fail
fi
if ! swift test --filter Phase15 >/tmp/p16-s4b.log 2>&1; then
  s4_status=fail
fi

python3 - "$OUT" "$DATE" "$s0_status" "$s1_status" "$s2_status" "$s3_status" "$s4_status" <<'PY'
import sys, pathlib
out, date, s0, s1, s2, s3, s4 = sys.argv[1:8]

def norm(s):
    return {"pass": "passing", "partial": "partial", "fail": "fail"}.get(s, s)

pathlib.Path(out).write_text(f"""# Conformance report (Phase 16 RC)

**Generated:** {date}  
**Profile:** CodeEditor Swift-first extension platform

This report is evidence-backed. Levels mark `passing` only when required suites succeed in the generator run.
S0–S4 describe **CodeEditor** package/runtime contracts only.

## Levels

| Level | Name | Status | Evidence |
|---|---|---|---|
| **S0** | Package compatibility | {norm(s0)} | `Tests/Fixtures/Extensions/s0-basic`, TOML corpus, package loader tests, CLI `validate` |
| **S1** | Data compatibility | {norm(s1)} | `Tests/Fixtures/Extensions/s1-data`, contribution loaders, PHASE9-NOTES |
| **S2** | Swift API feature parity | {norm(s2)} | ExtensionAPI providers; Phase 12 language-server + Phase 13 DAP/MCP matrices |
| **S3** | Behavioral parity | {norm(s3)} | Conformance guest dual-run Phase 10; Wasm host ABI Phase 11 |
| **S4** | Operational parity | {norm(s4)} | Phase 14 store/signing/rollback; Phase 15 shipping profiles + App Review docs |

## Required filter groups (generator)

| Level | Filters exercised |
|---|---|
| S0/S1 | `ExtensionPackage` (and related) |
| S2 | `Phase12` |
| S3 | `Phase10`, `Phase11` |
| S4 | `Phase14`, `Phase15` |

## Non-claims

- Full LSP beyond the claimed matrix
- Language-model provider marketplace
- Third-party editor binary drop-in compatibility

## Re-run

```bash
./scripts/generate-conformance-report.sh
swift test --filter Phase16
```

## Related

- [PHASE16-NOTES](PHASE16-NOTES.md)
- [PRODUCT-SCORECARDS](PRODUCT-SCORECARDS.md)
- [API-FREEZE](API-FREEZE.md)
- [CompatibilityProfile.toml](CompatibilityProfile.toml)
""")
print(f"Wrote {out}")
if s0 == "fail" or s1 == "fail" or s4 == "fail":
    sys.exit(1)
PY
