# Tranche 1 migration notes

## What changed

The package is split into modular products. Existing simple APIs still work when you link the right products and bootstrap language packs.

### Before

```
CodeEditorView → CodeEditorLanguages → all TreeSitter*Grammar targets
```

### After

```
CodeEditorCore
CodeEditorLanguageSupport
CodeEditorTreeSitter
CodeEditorView → Core + LanguageSupport + TreeSitter   (no grammars)
CodeEditorLanguageSwift / JSON  (pilot packs)
CodeEditorLanguages             (umbrella: all grammars + bootstrap)
```

## Consumer migration

1. **Editor only, no highlighting**  
   Link `CodeEditorView` only. `language: nil` / plain text.

2. **One language (e.g. Swift)**  
   Link `CodeEditorView` + `CodeEditorLanguageSwift`. Call once:

   ```swift
   CodeEditorLanguageSwift.register()
   ```

3. **Full catalog (previous default)**  
   Link `CodeEditorView` + `CodeEditorLanguages`. Call once:

   ```swift
   CodeEditorLanguages.bootstrap()
   ```

   Catalog APIs (`CodeLanguages.language(id:)`, `CodeLanguage.swift`, …) still exist and force bootstrap when used.

4. **Headless core**  
   Link `CodeEditorCore` for document/selection/undo without UI.

## Compatibility

- `import CodeEditorView` re-exports Core, LanguageSupport, and TreeSitter.
- `import CodeEditorLanguages` re-exports LanguageSupport + TreeSitter.
- `CodeLanguage`, `TreeSitterLanguageID`, `language: .swift` remain available.
- Open `LanguageID("company.dsl")` can be registered via `LanguageRegistry` without a closed enum case.

## Verification

```bash
scripts/check-product-isolation.sh
swift test
```

## Deferred (later phases)

- Per-language products beyond Swift/JSON pilots
- Versioned `EditTransaction` / multi-session documents
- Commands, workspace, workbench, LSP, extensions, search, terminal, SCM
