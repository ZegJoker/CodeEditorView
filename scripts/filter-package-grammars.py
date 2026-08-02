#!/usr/bin/env python3
"""RETIRED (PKG-001).

Previously rewrote Package.swift to drop missing Grammars/src paths (nondeterministic shape).
Grammar C sources are now committed under Packages/CodeEditorGrammars.

This script intentionally fails if invoked so CI/docs cannot rely on it.
"""
import sys
print(
    "FAIL: filter-package-grammars.py is retired. "
    "Use committed Packages/CodeEditorGrammars (see scripts/update-grammars.sh).",
    file=sys.stderr,
)
sys.exit(1)
