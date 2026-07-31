# Product owners

Default owner for all products is the repository maintainer until multi-owner staffing exists. Phase and PR authors act as temporary owners for the products they change and must update gate evidence in the relevant `PHASE*-NOTES.md`.

| Product | Owner | Interim stability (ADR-012) | Program target gate (ADR-013) | Notes |
|---|---|---|---|---|
| CodeEditorCore | maintainer | Stable | Phase 2 | Foundation for all products |
| CodeEditorDocuments | maintainer | Stable | Phase 2 | Atomic I/O, recovery |
| CodeEditorCommands | maintainer | Evolving | Phase 3 | Async commands, keybindings |
| CodeEditorWorkspace | maintainer | Evolving | Phase 3 | Transactions, watchers |
| CodeEditorSearch | maintainer | Evolving | Phase 3 | Streaming search/replace |
| CodeEditorLanguageSupport | maintainer | Stable | Phase 4 | Detection/registry |
| CodeEditorTreeSitter | maintainer | Stable | Phase 4 | Queries, provenance |
| CodeEditorLanguageSwift | maintainer | Stable | Phase 4 | Pack registration |
| CodeEditorLanguageJSON | maintainer | Stable | Phase 4 | Pack registration |
| CodeEditorLanguages | maintainer | Stable | Phase 4 | Multi-language bootstrap |
| CodeEditorView | maintainer | Stable | Phase 5 | Façade reduction, UI quality |
| CodeEditorLanguageServices | maintainer | Evolving | Phase 6 | Provider arbitration |
| CodeEditorLSP | maintainer | Experimental | Phase 6 | Protocol completeness |
| CodeEditorTasks | maintainer | Evolving | Phase 7 | Process groups |
| CodeEditorTerminal | maintainer | Experimental | Phase 7 | PTY + VT |
| CodeEditorSourceControl | maintainer | Experimental | Phase 7 | Robust Git |
| CodeEditorWorkbench | maintainer | Evolving | Phase 8 | Contribution isolation |
| CodeEditorExtensionAPI | maintainer | Experimental | Phase 9 | Author SDK, TOML, digests |
| CodeEditorExtensionProtocol | maintainer | Experimental | Phase 10 | CBOR wire, catalog, framing |
| CodeEditorExtensionGuest | maintainer | Experimental | Phase 10 | Native guest runtime |
| CodeEditorWasmEngine | maintainer | Experimental | Phase 11 | Wasm engine protocol |
| CodeEditorWasmEngineWasmKit | maintainer | Experimental | Phase 11 | WasmKit backend |
| CodeEditorExtensionWasmGuest | maintainer | Experimental | Phase 11 | Core-Wasm guest glue |
| CodeEditorExtensions | maintainer | Experimental | Phase 9–14 | Runtime, package manager, façade |
| CodeEditorExtensionHost | maintainer | Experimental | Phase 10–15 | Multi-runtime host, broker, trust |
| CodeEditorExtensionTesting | maintainer | *new* | Phase 10+ | Author test harness |
| CodeEditorDAP | maintainer | *new* | Phase 13+ | Debug adapter protocol |

## Program rules

1. No public feature merge without: owner (or PR author as acting owner), platform contract note, test plan, and stability classification.
2. Cross-product changes list all affected products in the PR/commit body.
3. Extension platform work must not silently expand View/Workbench public surface.
