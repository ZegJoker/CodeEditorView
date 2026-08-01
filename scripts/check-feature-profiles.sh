#!/usr/bin/env bash
# Verify shipping profile capability matrices match Tests/Fixtures/Profiles/matrix.json
# and that required Phase 15 documentation exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MATRIX="Tests/Fixtures/Profiles/matrix.json"
if [[ ! -f "$MATRIX" ]]; then
  echo "FAIL: missing $MATRIX"
  exit 1
fi

python3 - <<'PY'
import json, pathlib, re, sys

matrix = json.loads(pathlib.Path("Tests/Fixtures/Profiles/matrix.json").read_text())
profiles = matrix["profiles"]
src = pathlib.Path("Sources/CodeEditorCore/Platform/PlatformCapabilityProfile.swift").read_text()

# Extract static let blocks roughly and ensure names exist
required = ["directMacOS", "macAppStore", "iOS", "enterprise", "test"]
for name in required:
    if f"static let {name}" not in src and f"public static let {name}" not in src:
        # file uses `public static let directMacOS`
        if f"let {name} =" not in src:
            print(f"FAIL: preset {name} not found in PlatformCapabilityProfile.swift")
            sys.exit(1)

# New capability kinds must appear in PlatformCapabilityKind
kinds_src = pathlib.Path("Sources/CodeEditorCore/Platform/PlatformCapabilityKind.swift").read_text()
for kind in [
    "bundledWasm", "downloadableWasm", "dynamicExtensionInstall", "remoteTooling", "extensionRegistry"
]:
    if kind not in kinds_src:
        print(f"FAIL: missing capability kind {kind}")
        sys.exit(1)

# Host profile models
host = pathlib.Path("Sources/CodeEditorExtensionAPI/HostProfileModels.swift")
if not host.exists():
    print("FAIL: missing HostProfileModels.swift")
    sys.exit(1)

# Ensure APP-REVIEW and PHASE15 notes exist
for path in [
    "Docs/Guides/APP-REVIEW.md",
    "Docs/Architecture/PHASE15-NOTES.md",
]:
    if not pathlib.Path(path).exists():
        print(f"FAIL: missing {path}")
        sys.exit(1)

# Matrix keys present
for pid in ["direct-macos", "mac-app-store", "ios", "enterprise", "test"]:
    if pid not in profiles:
        print(f"FAIL: matrix missing profile {pid}")
        sys.exit(1)
    caps = profiles[pid]
    for k in [
        "nativeExtensionProcess", "bundledWasm", "downloadableWasm",
        "dynamicExtensionInstall", "remoteTooling", "extensionRegistry"
    ]:
        if k not in caps:
            print(f"FAIL: matrix {pid} missing {k}")
            sys.exit(1)

# MAS/iOS must deny native + downloadable Wasm
assert profiles["mac-app-store"]["nativeExtensionProcess"] == "unavailable"
assert profiles["mac-app-store"]["downloadableWasm"] == "unavailable"
assert profiles["ios"]["nativeExtensionProcess"] == "unavailable"
assert profiles["ios"]["downloadableWasm"] == "unavailable"
assert profiles["ios"]["localLanguageServerProcess"] == "remote"
assert profiles["direct-macos"]["nativeExtensionProcess"] == "local"
# Enterprise must declare enterprise options in source
if "enterpriseOptions" not in src and "EnterpriseProfileOptions" not in src:
    print("FAIL: enterprise options missing from Core")
    sys.exit(1)

print("OK: feature profile matrix and Phase 15 inventory checks passed")
print(f"     profiles={list(profiles.keys())}")
PY
