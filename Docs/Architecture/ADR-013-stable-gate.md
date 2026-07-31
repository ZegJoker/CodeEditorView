# ADR-013: Evidence-based Stable gate

## Status

Accepted (Phase 0 — stabilization program)

## Context

ADR-012 classified products as Stable / Evolving / Experimental based on modularization maturity. The stabilization program replaces that tier-only promise with an **evidence-based Stable gate**: a product is Stable only when API, correctness, concurrency, tests, platform honesty, operations, and documentation criteria are met.

ADR-012 remains historically valid for the pre-program 1.0 modularization snapshot. Until every product passes this gate, public docs may still list interim tiers, but program work is measured against this ADR.

## Decision

1. Every public library product must pass **all applicable gates** in the stabilization plan before it is declared program-Stable:
   - API and semantic-versioning (symbol-graph baseline, no accidental public surface, no bare `Any` / unjustified `@unchecked Sendable`)
   - Correctness and data-safety (no known P0/P1, atomic mutations or recovery journals, real cancellation)
   - Concurrency (Swift 6 strict concurrency, actor isolation, TSan where supported)
   - Tests (per-product coverage targets, property/fuzz where listed)
   - Platform (explicit `PlatformCapabilityProfile`; fail closed on unsupported capabilities)
   - Operations and diagnostics (structured logs, metrics without source exfiltration)
   - Documentation (overview, selection guide, platform table, migration, troubleshooting)

2. Stable products must not re-export Experimental implementation surfaces.

3. New products (`CodeEditorExtensionAPI`, `CodeEditorExtensionTesting`, `CodeEditorDAP`, …) require the same gate before a 1.0-stable claim.

4. Each phase of the program records exit evidence in `PHASE*-NOTES.md`.

## Consequences

- “Stable” in marketing/docs becomes an evidence claim, not a label.
- Work prioritizes gates over feature breadth.
- CI (Phase 1+) must make gate evidence automatable.
