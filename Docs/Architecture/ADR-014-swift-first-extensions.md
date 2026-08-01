# ADR-014: Swift-first extension platform

## Status

Accepted (Phase 0)

## Context

The repository has an in-process `CodeEditorExtension` protocol, JSON data extensions (`extension.json`), and a process-RPC extension host. Industry editors often use declarative package roots, contribution folders, and sandboxed guests. CodeEditorView targets the same **classes of capability** with a **Swift-first** author SDK and CodeEditor-owned package/runtime contracts—without requiring authors to use another language or load foreign guest binaries.

## Decision

1. **Authoring language:** Swift is the only required procedural language for extensions. Public templates, examples, and docs use Swift.

2. **Package model:** Canonical manifest is `extension.toml` (schema v1). Conventional folders for languages, grammars, themes, icon themes, snippets, and assets. Declarative contributions load without executing procedural code.

3. **Author API product:** `CodeEditorExtensionAPI` is a small, transport-neutral public product. Extension authors depend only on it (plus `CodeEditorExtensionTesting` for tests). It must not depend on View, Workbench, AppKit/UIKit/SwiftUI, Process, or Wasm engines.

4. **Runtime profiles** (host chooses based on artifacts, trust, and platform policy):

   | Profile | Use |
   |---|---|
   | Built-in Swift | Trusted, statically linked (default first-party iOS/macOS) |
   | Data-only | TOML/JSON assets and queries; no executable code |
   | Native Swift process | Signed Swift executable on direct-distribution macOS; crash isolation, not a full sandbox |
   | Swift-Wasm | Preferred technical sandbox for untrusted/portable code where policy allows |

   Optional remote providers may expose process-backed tooling to iOS without downloading native code.

5. **Compatibility levels** (see `CompatibilityProfile.toml`):

   - **S0–S4** are the first stable release targets (package, data, Swift API feature parity, behavioral parity, operational parity).
6. **Wire formats:** Process and Wasm use a CodeEditor-owned versioned message ABI (CBOR envelopes). JSON may remain for diagnostics and legacy.

7. **Migration:** Keep source-compatible shims in `CodeEditorExtensions` for one major. Read `extension.json` only under a legacy flag; `extension.toml` wins on conflict. Evolve existing runtime/process RPC rather than rewrite from zero.

## Non-goals (first stable release)

- Requiring a non-Swift language for authors
- Drop-in compatibility with third-party editor guest ABIs or package binaries
- Arbitrary native view construction
- Runtime Swift compilation
- Downloadable native Swift on iOS
- Claiming native process helpers are safe for untrusted marketplace code without OS sandboxing

## Consequences

- Phase 9 extracts the author API and TOML path; Phases 10–11 add native and Wasm drivers.
- Existing `CodeEditorExtension` remains the built-in adapter.
- Documentation must describe S0–S4 as CodeEditor contracts only—not third-party binary compatibility.
