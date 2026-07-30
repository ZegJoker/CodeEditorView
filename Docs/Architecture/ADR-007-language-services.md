# ADR-007: Generic language services

## Status

Accepted (Phase 8)

## Context

Phases 1–7 modularized core document, commands, workspace, and workbench products. Language intelligence today is fragmented:

- `HighlightProviding` (LanguageSupport) for paint
- `CodeSuggestionDelegate` / `JumpToDefinitionDelegate` (View) holding `EditorController`
- No protocol-neutral product for completion, diagnostics, hover, navigation, formatting, rename, symbols, code actions, semantic tokens, inlays, folding, signature help, links, or colors

Phase 10 LSP must implement contracts rather than invent them. Hosts also need pure mocks without a language server.

## Decision

1. **`CodeEditorLanguageServices` product** depends only on `CodeEditorCore`, `CodeEditorDocuments`, and `CodeEditorLanguageSupport`. It must not depend on View, Workbench, Workspace, TreeSitter, grammars, or LSP.

2. **Capability protocols** (`CompletionProvider`, `HoverProvider`, `DefinitionProvider`, …) are `Sendable` with async methods. Shared metadata: `ProviderID`, `DocumentSelector`, `priority`.

3. **`LanguageServiceRegistry`** is an **actor** for thread-safe registration. **`LanguageServiceHost`** selects matching providers, applies merge policies, and re-checks document version after awaits.

4. **Merge policies**

   | Capability | Policy |
   |---|---|
   | Completion | Merge all by priority; dedupe by label + edit |
   | Diagnostics | Merge all; sort by range then severity |
   | Definition / declaration / implementation / references | Merge all (dedupe locations) |
   | Hover | Merge sections up to a cap |
   | Document / workspace symbols | Merge all |
   | Code actions | Merge all |
   | Formatting | Highest priority non-empty only |
   | Rename | Highest priority only |
   | Semantic tokens | Concatenate spans (tag provider id) |
   | Folding | First non-empty by priority |
   | Signature help | Highest priority only |
   | Inlay hints / links / colors | Merge all |

5. **Versioning** — requests carry `DocumentSnapshot.version`. Host methods take `currentVersion: () -> DocumentVersion` and throw `LanguageServiceError.staleVersion` when the document moved on. Cancellation uses `Task.checkCancellation()`.

6. **Completion must not apply edits** — items carry `TextEditPlan` / `insertText`; View adapters apply via controller transactions.

7. **View adapters** live in `CodeEditorView/LanguageServices/` so LanguageServices stays free of `EditorController`:
   - `CompletionProviderDelegateAdapter`
   - `DefinitionProviderJumpAdapter`
   - `DiagnosticsAnnotationMapper`
   - `SemanticTokensHighlightAdapter`
   - `FoldingRangeProviderAdapter`
   - Optional `EditorController.installLanguageServices(_:context:)`

8. **`MockLanguageSuite`** implements every capability for tests without LSP.

## Consequences

- Phase 10 `CodeEditorLSP` implements the same provider protocols.
- Phase 9 extensions can register providers into the same registry.
- Existing `CodeSuggestionDelegate` / `JumpToDefinitionDelegate` continue to work; language services are opt-in via adapters.
- Isolation script forbids View/UI/LSP/TreeSitter imports in LanguageServices.
