#!/usr/bin/env bash
# Extract public API inventory from Sources/<Product> into Baselines/api/<Product>.public.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-Baselines/api}"
mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import re, pathlib, sys
out_root = pathlib.Path(sys.argv[1])
out_root.mkdir(parents=True, exist_ok=True)
products = [
  "CodeEditorCore","CodeEditorDocuments","CodeEditorCommands","CodeEditorWorkspace",
  "CodeEditorWorkbench","CodeEditorView","CodeEditorLanguageSupport","CodeEditorLanguageServices",
  "CodeEditorExtensionAPI","CodeEditorExtensionProtocol","CodeEditorExtensionGuest",
  "CodeEditorWasmEngine","CodeEditorWasmEngineWasmKit","CodeEditorExtensionWasmGuest",
  "CodeEditorExtensions","CodeEditorExtensionHost","CodeEditorLSP","CodeEditorDAP",
  "CodeEditorSearch","CodeEditorTasks","CodeEditorTerminal","CodeEditorSourceControl",
  "CodeEditorTreeSitter","CodeEditorLanguageSwift","CodeEditorLanguageJSON","CodeEditorLanguages",
]
pat_func = re.compile(r'^\s*public\s+(?:static\s+|class\s+|mutating\s+|nonmutating\s+|override\s+|async\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)')
pat_type = re.compile(r'^\s*public\s+(?:final\s+|indirect\s+)?(struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)')
pat_var = re.compile(r'^\s*public\s+(?:static\s+|class\s+|lazy\s+|weak\s+|unowned(?:\(safe\)|\(unsafe\))?\s+)*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)')
index = []
for p in products:
    src = pathlib.Path("Sources") / p
    symbols = set()
    if src.exists():
        for f in src.rglob("*.swift"):
            if "Documentation.docc" in str(f):
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            for line in text.splitlines():
                if "public " not in line:
                    continue
                m = pat_type.match(line)
                if m:
                    symbols.add(f"{m.group(1)} {m.group(2)}")
                    continue
                m = pat_func.match(line)
                if m:
                    symbols.add(f"func {m.group(1)}")
                    continue
                m = pat_var.match(line)
                if m:
                    symbols.add(f"var {m.group(1)}")
    lines = sorted(symbols)
    (out_root / f"{p}.public.txt").write_text("\n".join(lines) + ("\n" if lines else ""))
    index.append(f"{p}\t{len(lines)}")
    print(f"OK:   {p} ({len(lines)} symbols)")
(out_root / "PRODUCTS.txt").write_text(
    "# API freeze public-surface inventory (source-extracted)\n"
    + "\n".join(index) + "\n"
)
print(f"Wrote inventories under {out_root}")
PY
