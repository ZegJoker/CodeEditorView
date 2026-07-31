# ADR-001: Dependency direction for modular CodeEditorView

## Status

Accepted (first modularization tranche)

## Context

`CodeEditorView` currently depends on `CodeEditorLanguages`, which links every Tree-sitter grammar. A “small editor” product therefore compiles and links the full language bundle. The modular framework plan requires optional capabilities to depend inward on lightweight contracts; the core must never depend outward on grammars, LSP, Git, terminal, or workbench UI.

## Decision

1. **Dependency rule:** every dependency points from optional, higher-level products toward smaller contracts or core products. No lower-level product imports an optional implementation.

2. **First-tranche products:**
   - `CodeEditorCore` — platform-neutral document, index, selection, undo, formation, events
   - `CodeEditorLanguageSupport` — open `LanguageID`, definitions, registry (no parsers)
   - `CodeEditorTreeSitter` — generic Tree-sitter lifecycle and highlight provider (no grammar C targets)
   - `CodeEditorLanguage*` — per-language grammar + queries + pack registration
   - `CodeEditorLanguages` — convenience umbrella that registers all packs
   - `CodeEditorView` — embeddable editor UI; may depend on Core, LanguageSupport, TreeSitter; **must not** depend on grammar products or the all-language umbrella

3. **Import allowlists (enforced by scripts as they land):**

   | Target | Forbidden imports / deps |
   |---|---|
   | `CodeEditorCore` | SwiftUI, AppKit, UIKit, SwiftTreeSitter, any `TreeSitter*Grammar`, `CodeEditorLanguages` |
   | `CodeEditorLanguageSupport` | SwiftUI, AppKit, UIKit, SwiftTreeSitter, grammar targets |
   | `CodeEditorTreeSitter` | grammar targets, AppKit/UIKit/SwiftUI |
   | `CodeEditorView` | any `TreeSitter*Grammar`, `CodeEditorLanguages` |

4. **Compatibility:** keep `CodeEditor` / `EditorController` façades and a `CodeLanguage`-shaped API. Closed `TreeSitterLanguageID` remains only as a compatibility catalog for the umbrella product, not as the public extension boundary.

5. **Deferred:** workspace, workbench, commands product, LSP, extensions, search, tasks, terminal, source control (later phases).

## Consequences

- Hosts that want syntax highlighting link one or more language packs (or the umbrella) and ensure packs are registered with `LanguageRegistry`.
- Build/link cost for a Swift-only editor drops to a single grammar.
- Tree-sitter C grammars under `Grammars/` are **not** checked into git; developers (and CI) run `scripts/update-grammars.sh` (see README).
- Tests that exercise highlighting must depend on the packs (or umbrella) they need.

## Baseline (2026-07-30, branch `feat/modular-framework-tranche-1`)

- `swift test`: **219 tests in 57 suites, all passed** (~11s on this machine)
- Public products before change: `CodeEditorView`, `CodeEditorLanguages`
- `EditorController.swift`: ~1,240 lines
- Grammar targets: 39 languages under `Grammars/src/`
