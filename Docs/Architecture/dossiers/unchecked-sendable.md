# Unchecked Sendable dossier (REL-N07)

Policy for every `@unchecked Sendable` site under `Sources/`.

## Required fields (per site)

| Field | Meaning |
|---|---|
| invariant | Why the type is safe despite unchecked Sendable |
| owner | Module/team responsible for the invariant |
| synchronization | Actor, lock, queue, or immutability strategy |
| stress | Test or soak that exercises concurrent access |
| removal path | How the site will become checked Sendable |

## Global rules

1. New sites require updating `Baselines/unchecked-sendable-allowlist.txt` **and** an entry in this dossier (or inventory regeneration with rationale).
2. Count is ratcheted downward: `scripts/check-unchecked-sendable.sh` fails on any site not in the allowlist.
3. CI `strict-concurrency` job uses `-strict-concurrency=complete` with **warnings-as-errors**.
4. Thread Sanitizer jobs must execute tests (see `scripts/run-sanitizers.sh`), not only compile.

## Inventory

Generated inventory: `Docs/Architecture/UNCHECKED-SENDABLE.md`  
Allowlist: `Baselines/unchecked-sendable-allowlist.txt`  
Current count is maintained by `scripts/generate-unchecked-sendable-inventory.sh`.

## Site classes (summary)

| Class | invariant | owner | synchronization | stress | removal path |
|---|---|---|---|---|---|
| Framing decoders (LSP/DAP/RPC/CBOR) | Buffer mutated only on owner queue | transport owners | lock / single consumer | transport unit tests | isolate decoder actor |
| Process handles | Process lifecycle exclusive | CodeEditorCore | lock around Process | process tests | ProcessSupervisor actor |
| Contribution stores | Main-actor affine or lock | Extensions | lock | host tests | actor isolation |
| Test transports (legacy) | Test-only duplex pairs | tests | lock | suite | move fully to Tests/ |
| Language registry / bootstrap | Lazy init once | Languages | lock | bootstrap tests | actor |
| JSON boxes | Immutable after parse or locked | LSP/DAP | value snapshot | matrix tests | structured Sendable DTOs |

Per-file line items live in the generated inventory. Adding a site without allowlist + dossier update fails CI.
