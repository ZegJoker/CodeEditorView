#!/usr/bin/env bash
# REL-N06 — extract semantic public API inventory from Sources/<Product>.
# Emits declarations with signatures, Sendable, actor isolation, and availability
# markers (best-effort source parse; complements symbol-graph CI).
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
  "CodeEditorTerminalGhostty",
]

attr_re = re.compile(r'@\w+(?:\([^)]*\))?')
# Capture public declarations; include modifiers on the same logical line (simple).
type_re = re.compile(
    r'^\s*(?:@\S+\s+)*public\s+(?:final\s+|indirect\s+|open\s+)?(struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)'
)
func_re = re.compile(
    r'^\s*(?:@\S+\s+)*public\s+(?:static\s+|class\s+|mutating\s+|nonmutating\s+|override\s+|async\s+|final\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)\s*(\([^;{]*\))?'
)
init_re = re.compile(
    r'^\s*(?:@\S+\s+)*public\s+(?:required\s+|convenience\s+)*init\s*(\([^;{]*\))?'
)
var_re = re.compile(
    r'^\s*(?:@\S+\s+)*public\s+(?:static\s+|class\s+|lazy\s+|weak\s+|unowned(?:\(safe\)|\(unsafe\))?\s+)*(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)'
)
sendable_re = re.compile(r':\s*[^{]*\bSendable\b|@unchecked\s+Sendable|\bSendable\b')
mainactor_re = re.compile(r'@MainActor')
avail_re = re.compile(r'@available\(([^)]*)\)')

def attrs_prefix(line: str) -> str:
    tags = []
    if mainactor_re.search(line):
        tags.append("isolation=@MainActor")
    if "nonisolated" in line:
        tags.append("isolation=nonisolated")
    if sendable_re.search(line):
        tags.append("sendable=1")
    for m in avail_re.finditer(line):
        tags.append(f"availability={m.group(1).strip()}")
    if "@discardableResult" in line:
        tags.append("attr=discardableResult")
    return (" | " + " ".join(tags)) if tags else ""

def normalize_sig(sig):
    if not sig:
        return "()"
    s = re.sub(r'\s+', ' ', sig.strip())
    # strip default argument values for stability: x: Int = 1 -> x: Int
    s = re.sub(r'=\s*[^,\)]+', '', s)
    s = re.sub(r'\s+', ' ', s)
    return s

index = []
for p in products:
    src = pathlib.Path("Sources") / p
    symbols = set()
    if src.exists():
        for f in src.rglob("*.swift"):
            if "Documentation.docc" in str(f):
                continue
            # Skip pure test doubles if any remain under Testing/
            if "/Testing/" in str(f) and "Mock" in f.name:
                continue
            try:
                text = f.read_text(encoding="utf-8", errors="replace")
            except Exception:
                continue
            # simple multi-line: join lines that continue signatures ending with comma
            lines = text.splitlines()
            i = 0
            while i < len(lines):
                line = lines[i]
                # accumulate attribute lines above public decls
                lookback = []
                j = i
                raw = line
                # include previous attr-only lines
                k = i - 1
                prefix = ""
                while k >= 0 and lines[k].strip().startswith("@"):
                    prefix = lines[k].strip() + " " + prefix
                    k -= 1
                full = prefix + raw
                if "public " not in full and not full.strip().startswith("public "):
                    i += 1
                    continue
                m = type_re.match(full) or type_re.match(raw)
                if m:
                    symbols.add(f"{m.group(1)} {m.group(2)}" + attrs_prefix(full))
                    i += 1
                    continue
                m = init_re.match(full) or init_re.match(raw)
                if m:
                    # may need following lines for signature
                    sig = m.group(1) or "()"
                    if "(" in raw and ")" not in raw:
                        buf = raw
                        t = i + 1
                        while t < len(lines) and ")" not in buf:
                            buf += " " + lines[t].strip()
                            t += 1
                        mm = init_re.match(prefix + buf) or re.search(r'init\s*(\([^;{]*\))', buf)
                        if mm:
                            sig = mm.group(1) if mm.lastindex else "()"
                    symbols.add(f"init {normalize_sig(sig)}" + attrs_prefix(full))
                    i += 1
                    continue
                m = func_re.match(full) or func_re.match(raw)
                if m:
                    name = m.group(1)
                    sig = m.group(2)
                    if sig is None or (sig and sig.count("(") > sig.count(")")):
                        buf = raw
                        t = i + 1
                        while t < len(lines) and (")" not in buf or buf.count("(") > buf.count(")")):
                            buf += " " + lines[t].strip()
                            t += 1
                            if "{" in lines[t-1] or buf.rstrip().endswith("{"):
                                break
                        mm = re.search(r'func\s+[A-Za-z_][A-Za-z0-9_]*\s*(\([^;{]*)', buf)
                        if mm:
                            sig = mm.group(1)
                            if not sig.endswith(")"):
                                # take until first ) 
                                if ")" in buf:
                                    sig = buf[buf.find("("):buf.find(")")+1]
                    symbols.add(f"func {name}{normalize_sig(sig)}" + attrs_prefix(full))
                    i += 1
                    continue
                m = var_re.match(full) or var_re.match(raw)
                if m:
                    symbols.add(f"var {m.group(1)}" + attrs_prefix(full))
                    i += 1
                    continue
                i += 1
    lines_out = sorted(symbols)
    (out_root / f"{p}.public.txt").write_text("\n".join(lines_out) + ("\n" if lines_out else ""))
    index.append(f"{p}\t{len(lines_out)}")
    print(f"OK:   {p} ({len(lines_out)} symbols)")
(out_root / "PRODUCTS.txt").write_text(
    "# API freeze public-surface inventory (semantic source extract)\n"
    + "\n".join(index) + "\n"
)
print(f"Wrote inventories under {out_root}")
PY
