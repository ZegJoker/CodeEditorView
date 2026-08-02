# Ghostty conformance fixtures (TER-N09 / TER-N10)

These fixtures document the linked-library corpus required before Stable.

## Corpus list

| Fixture | Covers |
|---------|--------|
| `ansi-corpus.txt` | SGR colors, cursor, erase, basic VT |
| `utf8-split.txt` | Multi-byte UTF-8 split at every byte boundary |
| `wide-emoji.txt` | Wide cells, ZWJ emoji, combining marks |
| `mouse-focus.txt` | Mouse reporting modes + focus in/out |

## Linked execution

```bash
# Hard gate (CI):
REQUIRE_GHOSTTY=1 ./scripts/check-ghostty-linked.sh

# Full 100 MiB soak (optional):
GHOSTTY_FULL_SOAK=1 CODEEDITOR_GHOSTTY_LINKED=1 swift test --filter GhosttyConformance
```

When `ce_ghostty_is_linked()==false`, unit tests assert fail-closed + fixture presence.
They must not soft-pass as if the linked VT corpus ran.
