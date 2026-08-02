#!/usr/bin/env bash
# Inventory third-party package dependencies from Package.resolved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RESOLVED="Package.resolved"
if [[ ! -f "$RESOLVED" ]]; then
  echo "Package.resolved missing — run swift package resolve" >&2
  exit 1
fi

echo "== Package dependencies (Package.resolved) =="

python3 - <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path("Package.resolved").read_text())
# SPM v2/v3 shapes
pins = data.get("pins") or data.get("object", {}).get("pins") or []
if not pins:
    print("FAIL: no pins found in Package.resolved", file=sys.stderr)
    sys.exit(1)
for pin in pins:
    identity = pin.get("identity") or pin.get("package")
    location = pin.get("location") or pin.get("repositoryURL")
    state = pin.get("state") or {}
    version = state.get("version") or state.get("revision") or state.get("branch") or "?"
    print(f"OK:   {identity} @ {version}")
    print(f"      {location}")
print()
print(f"{len(pins)} dependency pin(s). Review licenses before redistribution.")
# Known OSS licenses for direct deps (manual map; update when adding packages).
# Apple Swift open-source packages are Apache-2.0; WasmKit is Apache-2.0.
KNOWN = {
    "swift-collections": "Apache-2.0",
    "swift-argument-parser": "Apache-2.0",
    "swift-atomics": "Apache-2.0",
    "swift-log": "Apache-2.0",
    "swift-nio": "Apache-2.0",
    "swift-system": "Apache-2.0",
    "swift-tree-sitter": "MIT",
    "textstory": "BSD-3-Clause",
    "TextStory": "BSD-3-Clause",
    "rearrange": "BSD-3-Clause",
    "Rearrange": "BSD-3-Clause",
    "tree-sitter": "MIT",
    "wasmkit": "Apache-2.0",
}
print("== Known license map (direct deps) ==")
unknown = []
for pin in pins:
    identity = pin.get("identity") or pin.get("package")
    lic = KNOWN.get(identity, "UNKNOWN — verify before release")
    status = "OK" if not lic.startswith("UNKNOWN") else "FAIL"
    print(f"{status}:  {identity}: {lic}")
    if lic.startswith("UNKNOWN"):
        unknown.append(identity)
if unknown:
    print("FAIL: unmapped licenses for:", ", ".join(unknown), file=sys.stderr)
    sys.exit(1)
print("OK:   all direct dependency licenses mapped")
PY
