#!/usr/bin/env bash
# Verifies modular product isolation rules (ADR-001).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

check_no_imports() {
  local target_dir="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -d "$target_dir" ]]; then
    echo "SKIP: missing $target_dir ($label)"
    return 0
  fi
  if rg -n --glob '*.swift' "$pattern" "$target_dir" >/tmp/cev-isolation-hits.txt 2>/dev/null; then
    echo "FAIL: $label — forbidden imports in $target_dir:"
    cat /tmp/cev-isolation-hits.txt
    fail=1
  else
    echo "OK:   $label"
  fi
}

check_package_view_deps() {
  # Ensure CodeEditorView target does not list CodeEditorLanguages or grammar targets.
  python3 - <<'PY'
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorView",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorView target not found in Package.swift")
    sys.exit(1)
deps = m.group(1)
bad = []
if "CodeEditorLanguages" in deps:
    bad.append("CodeEditorLanguages")
if re.search(r'TreeSitter\w+Grammar', deps):
    bad.append("TreeSitter*Grammar")
if bad:
    print("FAIL: CodeEditorView dependencies include:", ", ".join(bad))
    print(deps)
    sys.exit(1)
print("OK:   CodeEditorView Package.swift deps exclude grammars and CodeEditorLanguages")
PY
  if [[ $? -ne 0 ]]; then
    fail=1
  fi
}

echo "== CodeEditorCore import allowlist =="
check_no_imports "Sources/CodeEditorCore" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLanguageSupport|CodeEditorDocuments)' \
  "Core has no UI / Tree-sitter / language-pack imports"

echo "== CodeEditorDocuments import allowlist =="
check_no_imports "Sources/CodeEditorDocuments" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLanguageSupport|CodeEditorView)' \
  "Documents has no UI / Tree-sitter / View imports"

echo "== CodeEditorCommands import allowlist =="
check_no_imports "Sources/CodeEditorCommands" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLanguageSupport|CodeEditorView)' \
  "Commands has no UI / Tree-sitter / View imports"

echo "== CodeEditorWorkspace import allowlist =="
check_no_imports "Sources/CodeEditorWorkspace" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLanguageSupport|CodeEditorView|CodeEditorCommands)' \
  "Workspace has no UI / Tree-sitter / View / Commands imports"

echo "== CodeEditorLanguageSupport import allowlist =="
check_no_imports "Sources/CodeEditorLanguageSupport" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter)' \
  "LanguageSupport has no UI / Tree-sitter imports"

echo "== CodeEditorLanguageServices import allowlist =="
check_no_imports "Sources/CodeEditorLanguageServices" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorCommands|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP)' \
  "LanguageServices has no UI / View / Workbench / Tree-sitter / LSP imports"

echo "== CodeEditorWasmEngine import allowlist =="
check_no_imports "Sources/CodeEditorWasmEngine" \
  'import (SwiftUI|AppKit|UIKit|CodeEditorView|CodeEditorWorkbench|CodeEditorExtensionHost|CodeEditorExtensions|WasmKit)' \
  "WasmEngine core has no Host/UI/WasmKit imports"

echo "== CodeEditorExtensionWasmGuest import allowlist =="
check_no_imports "Sources/CodeEditorExtensionWasmGuest" \
  'import (SwiftUI|AppKit|UIKit|CodeEditorView|CodeEditorWorkbench|CodeEditorExtensionHost|CodeEditorExtensions|WasmKit|CodeEditorWasmEngine)' \
  "WasmGuest has no Host/WasmKit/Engine imports"

echo "== CodeEditorExtensionProtocol import allowlist =="
check_no_imports "Sources/CodeEditorExtensionProtocol" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions|CodeEditorExtensionHost|CodeEditorSearch|CodeEditorTasks|CodeEditorTerminal|CodeEditorSourceControl|ExtensionKit|WasmKit)' \
  "ExtensionProtocol has no host/UI/runtime/tooling imports"

echo "== CodeEditorExtensionGuest import allowlist =="
check_no_imports "Sources/CodeEditorExtensionGuest" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions|CodeEditorExtensionHost|CodeEditorSearch|CodeEditorTasks|CodeEditorTerminal|CodeEditorSourceControl|ExtensionKit|WasmKit)' \
  "ExtensionGuest has no host/UI/tooling imports"

echo "== CodeEditorExtensionAPI import allowlist =="
check_no_imports "Sources/CodeEditorExtensionAPI" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions|CodeEditorExtensionHost|CodeEditorSearch|CodeEditorTasks|CodeEditorTerminal|CodeEditorSourceControl|ExtensionKit|WasmKit|Process)' \
  "ExtensionAPI has no host/UI/runtime/tooling imports"

echo "== CodeEditorExtensions import allowlist =="
check_no_imports "Sources/CodeEditorExtensions" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|ExtensionKit)' \
  "Extensions has no UI / View / Workbench / Tree-sitter / LSP / ExtensionKit imports"

echo "== CodeEditorExtensionHost import allowlist =="
check_no_imports "Sources/CodeEditorExtensionHost" \
  'import (SwiftUI|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorSearch|CodeEditorTasks|CodeEditorTerminal|CodeEditorSourceControl)' \
  "ExtensionHost has no View / Workbench / LSP / tooling / Tree-sitter imports"
# Forbid private LaunchServices mutation APIs
if rg -n --glob '*.swift' 'LSSetDefault|LSRegisterURL|_LS|kLS' Sources/CodeEditorExtensionHost >/tmp/cev-ls-hits.txt 2>/dev/null; then
  echo "FAIL: ExtensionHost must not use private LaunchServices APIs:"
  cat /tmp/cev-ls-hits.txt
  fail=1
else
  echo "OK:   ExtensionHost has no private LaunchServices mutation APIs"
fi

echo "== CodeEditorLSP import allowlist =="
check_no_imports "Sources/CodeEditorLSP" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorCommands|CodeEditorExtensions|CodeEditorLanguages|CodeEditorTreeSitter|ExtensionKit)' \
  "LSP has no UI / View / Workbench / Extensions / Tree-sitter imports"

echo "== CodeEditorSearch import allowlist =="
check_no_imports "Sources/CodeEditorSearch" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions)' \
  "Search has no UI / View / Workbench / LSP / Tree-sitter imports"

echo "== CodeEditorTasks import allowlist =="
check_no_imports "Sources/CodeEditorTasks" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions)' \
  "Tasks has no UI / View / Workbench / LSP / Tree-sitter imports"

echo "== CodeEditorTerminal import allowlist =="
check_no_imports "Sources/CodeEditorTerminal" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorWorkspace|CodeEditorCommands|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions)' \
  "Terminal has no UI / View / Workbench / Workspace / Tree-sitter imports"

echo "== CodeEditorSourceControl import allowlist =="
check_no_imports "Sources/CodeEditorSourceControl" \
  'import (SwiftUI|AppKit|UIKit|SwiftTreeSitter|TreeSitter|CodeEditorView|CodeEditorWorkbench|CodeEditorLanguages|CodeEditorTreeSitter|CodeEditorLSP|CodeEditorExtensions)' \
  "SourceControl has no UI / View / Workbench / LSP / Tree-sitter imports"

echo "== CodeEditorTreeSitter grammar isolation =="
check_no_imports "Sources/CodeEditorTreeSitter" \
  'import TreeSitter\w+Grammar' \
  "TreeSitter module imports no grammar targets"

echo "== CodeEditorView grammar isolation =="
check_no_imports "Sources/CodeEditorView" \
  'import (CodeEditorLanguages|TreeSitter\w+Grammar)' \
  "View imports no CodeEditorLanguages / grammar modules"

echo "== Package.swift product graph =="
check_package_view_deps || true

echo "== CodeEditorLanguageServices Package.swift deps =="
python3 - <<'PY' || fail=1
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorLanguageServices",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorLanguageServices target not found")
    sys.exit(1)
deps = m.group(1)
allowed = {"CodeEditorCore", "CodeEditorDocuments", "CodeEditorLanguageSupport"}
# strip quotes/commas
found = set(re.findall(r'"([^"]+)"', deps))
bad = found - allowed
if bad:
    print("FAIL: LanguageServices unexpected deps:", ", ".join(sorted(bad)))
    sys.exit(1)
missing = allowed - found
if missing:
    print("FAIL: LanguageServices missing deps:", ", ".join(sorted(missing)))
    sys.exit(1)
print("OK:   LanguageServices Package.swift deps are Core+Documents+LanguageSupport only")
PY

echo "== CodeEditorExtensions Package.swift deps =="
python3 - <<'PY' || fail=1
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorExtensions",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorExtensions target not found")
    sys.exit(1)
deps = m.group(1)
allowed = {
    "CodeEditorExtensionAPI",
    "CodeEditorCore",
    "CodeEditorDocuments",
    "CodeEditorCommands",
    "CodeEditorLanguageSupport",
    "CodeEditorLanguageServices",
}
found = set(re.findall(r'"([^"]+)"', deps))
bad = found - allowed
if bad:
    print("FAIL: Extensions unexpected deps:", ", ".join(sorted(bad)))
    sys.exit(1)
missing = allowed - found
if missing:
    print("FAIL: Extensions missing deps:", ", ".join(sorted(missing)))
    sys.exit(1)
print("OK:   Extensions Package.swift deps are ExtensionAPI+Core+Documents+Commands+LanguageSupport+LanguageServices")
PY

echo "== CodeEditorExtensionAPI Package.swift deps =="
python3 - <<'PY' || fail=1
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorExtensionAPI",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorExtensionAPI target not found")
    sys.exit(1)
deps = m.group(1)
allowed = {
    "CodeEditorCore",
    "CodeEditorDocuments",
    "CodeEditorCommands",
    "CodeEditorLanguageSupport",
}
found = set(re.findall(r'"([^"]+)"', deps))
bad = found - allowed
if bad:
    print("FAIL: ExtensionAPI unexpected deps:", ", ".join(sorted(bad)))
    sys.exit(1)
missing = allowed - found
if missing:
    print("FAIL: ExtensionAPI missing deps:", ", ".join(sorted(missing)))
    sys.exit(1)
print("OK:   ExtensionAPI Package.swift deps are Core+Documents+Commands+LanguageSupport only")
PY

echo "== CodeEditorLSP Package.swift deps =="
python3 - <<'PY' || fail=1
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorLSP",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorLSP target not found")
    sys.exit(1)
deps = m.group(1)
allowed = {
    "CodeEditorCore",
    "CodeEditorDocuments",
    "CodeEditorLanguageSupport",
    "CodeEditorLanguageServices",
}
found = set(re.findall(r'"([^"]+)"', deps))
bad = found - allowed
if bad:
    print("FAIL: LSP unexpected deps:", ", ".join(sorted(bad)))
    sys.exit(1)
missing = allowed - found
if missing:
    print("FAIL: LSP missing deps:", ", ".join(sorted(missing)))
    sys.exit(1)
print("OK:   LSP Package.swift deps are Core+Documents+LanguageSupport+LanguageServices")
PY

echo "== CodeEditorWorkbench dependency isolation =="
python3 - <<'PY' || fail=1
import re, sys
text = open("Package.swift").read()
m = re.search(
    r'\.target\(\s*name:\s*"CodeEditorWorkbench",\s*dependencies:\s*\[(.*?)\]',
    text,
    re.S,
)
if not m:
    print("FAIL: CodeEditorWorkbench target not found")
    sys.exit(1)
deps = m.group(1)
forbidden = ["CodeEditorLSP", "CodeEditorSearch", "CodeEditorTerminal", "CodeEditorSourceControl", "CodeEditorLanguages", "TreeSitter"]
bad = [f for f in forbidden if f in deps]
if bad:
    print("FAIL: Workbench dependencies include forbidden:", ", ".join(bad))
    sys.exit(1)
print("OK:   Workbench Package.swift deps exclude LSP/search/terminal/SCM/all-grammars")
PY

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Product isolation checks FAILED."
  exit 1
fi

echo
echo "All product isolation checks passed."
