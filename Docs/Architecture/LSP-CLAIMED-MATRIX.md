# LSP claimed method matrix (residual closure)

This product does **not** claim every LSP 3.17 method. It claims the matrix below. Residual P16-005 is closed when each claimed client surface has automated coverage.

## Client → server (requests / notifications)

| Method | Session / path | Test evidence |
|---|---|---|
| `initialize` | `LanguageServerSession.start` | `LSPClientE2ETests.initializePopulatesCapabilities` |
| `initialized` | notify after init | same |
| `shutdown` / `exit` | `shutdown()` | E2E teardown |
| `textDocument/didOpen` | `didOpen` | `documentSyncOpenChangeClose` |
| `textDocument/didChange` | `didChange` / `didChangeRaw` | same |
| `textDocument/didSave` | `didSave` | Phase6 / E2E |
| `textDocument/didClose` | `didClose` | `documentSyncOpenChangeClose` |
| Generic request | `requestDictionary` / `requestJSON` | Phase6 adapter tests |
| Platform deny | process transport | `LSPPlatformTests` |

## Server → client (handled)

| Method | Handler | Test evidence |
|---|---|---|
| `textDocument/publishDiagnostics` | notification handler | bidirectional suite |
| `window/logMessage` | log | bidirectional suite |
| `workspace/applyEdit` | server request | bidirectional suite |
| `workspace/configuration` | server request | bidirectional suite |
| `workspace/workspaceFolders` | server request | bidirectional suite |

## LanguageServices adapters (capability-gated)

Claimed provider categories exercised via LSP adapters + Phase6 matrix: completion, hover, definition, references, document symbols, rename, code actions, signature help, type/call hierarchy prepare (as implemented).

## Explicit non-claims (not residuals)

- Full LSP 3.17 every method
- Language server implementation binaries (host-supplied)
- Unlisted experimental methods

## Gate

```bash
swift test --filter LSP
swift test --filter Phase16LSP
```
