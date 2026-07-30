# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with stability tiers described in `Docs/Guides/API-STABILITY.md`.

## [1.0.0] — Ready

First modular 1.0-ready release of the CodeEditorView package.

### Added

- Modular SwiftPM products for core, documents, commands, workspace, workbench, language services, extensions, extension host, LSP, search, tasks, terminal, and source control
- Product isolation script (`scripts/check-product-isolation.sh`)
- Architecture ADRs 001–012 and phase notes
- Guides: product selection, migration, extension authoring, API audit, API stability
- DocC landing pages for library products
- Examples: SmallEditor, FullWorkbench (plus existing CodeEditorViewDemo)

### Stability

- **Stable:** Core, Documents, LanguageSupport, View, TreeSitter, language pack registration
- **Evolving:** Commands, Workspace, Workbench, LanguageServices, Search, Tasks
- **Experimental:** Extensions, ExtensionHost, LSP, Terminal, SourceControl

### Notes

- Tagging `1.0.0` on the remote remains a maintainer action; this entry documents readiness.
- Experimental products may change in minor releases of 1.x.

## [0.x] — Pre-1.0 modularization

Incremental phases 1–12 delivered the product split prior to the stability policy in ADR-012.
