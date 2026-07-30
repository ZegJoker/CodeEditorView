# ADR-009: LSP client product

## Status

Accepted (Phase 10)

## Context

Phase 8 defined protocol-neutral language-service contracts. Hosts need a real Language Server Protocol client that implements those contracts without leaking LSP wire types into Core, View, or Workbench.

## Decision

1. **`CodeEditorLSP` product** depends only on Core, Documents, LanguageSupport, and LanguageServices.

2. **Three layers**
   - Transport: `LSPTestTransport`, `LSPProcessTransport`, custom host transports
   - JSON-RPC + Content-Length framing (`LSPJSONRPCConnection`)
   - Session/pool + document synchronizer + LanguageServices adapters

3. **Protocol types stay internal** to the LSP module. Public results use Phase 8 value types (`CompletionItem`, `LanguageDiagnostic`, `LocationLink`, …).

4. **Server pool identity** is `(LanguageServerID, workspace root URIs)`, not executable path alone.

5. **Document sync** is versioned and ordered (`didOpen` / `didChange` / `didSave` / `didClose`). Supports full and incremental change modes from server capabilities. Debouncing is optional and always sends the latest snapshot version.

6. **Crash policy** — transport failure marks the session `failed` and must **not** mutate host `TextDocument` content. Restart re-opens tracked documents from last known snapshots.

7. **Diagnostics** are primarily push (`textDocument/publishDiagnostics`) via `LanguageServerSession.diagnosticsStream`. Pull `DiagnosticsProvider` is registered as a no-op stub for registry completeness.

8. **Testing** uses `MockLanguageServer` over `LSPTestTransport` for CI; process transport is available for real servers outside CI.

## Consequences

- Hosts wire: pool → session → `LSPDocumentSynchronizer` → `LSPClientProviders.register` → `LanguageServiceHost` / View adapters.
- Server install UI remains out of scope.
- Full LSP method surface is intentionally subset; unsupported methods return empty/unavailable.
