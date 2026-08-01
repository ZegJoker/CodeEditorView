#!/usr/bin/env python3
"""Remove Package.swift grammar targets whose Grammars/src paths are missing (PKG-001)."""
from pathlib import Path
import re
import sys

def find_target_blocks(src: str):
    blocks = []
    i = 0
    while True:
        j = src.find(".target(", i)
        if j < 0:
            break
        depth = 0
        k = j
        while k < len(src):
            if src[k] == "(":
                depth += 1
            elif src[k] == ")":
                depth -= 1
                if depth == 0:
                    end = k + 1
                    while end < len(src) and src[end] in " \t":
                        end += 1
                    if end < len(src) and src[end] == ",":
                        end += 1
                    blocks.append((j, end, src[j:end]))
                    i = end
                    break
            k += 1
        else:
            break
    return blocks

def main():
    root = Path(__file__).resolve().parents[1]
    pkg = root / "Package.swift"
    text = pkg.read_text()
    to_remove = []
    names = []
    for start, end, block in find_target_blocks(text):
        m = re.search(r'path:\s*"(Grammars/src/[^"]+)"', block)
        if not m:
            continue
        path = root / m.group(1)
        name_m = re.search(r'name:\s*"([^"]+)"', block)
        name = name_m.group(1) if name_m else "?"
        if not path.exists():
            to_remove.append((start, end, name))
            names.append(name)
    if not names:
        print("OK: all grammar target paths present")
        return 0
    new_text = text
    for start, end, name in reversed(to_remove):
        new_text = new_text[:start] + new_text[end:]
        new_text = re.sub(rf'\s*"{re.escape(name)}",?\n', "\n", new_text)
    pkg.write_text(new_text)
    print(f"OK: removed {len(names)} missing grammar targets from Package.swift")
    for n in names:
        print(" -", n)
    return 0

if __name__ == "__main__":
    sys.exit(main())
