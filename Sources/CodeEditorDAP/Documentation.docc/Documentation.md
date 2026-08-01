# ``CodeEditorDAP``

Debug Adapter Protocol client.

## Overview

Host-owned DAP client/session model for debugger extensions. Extensions return launch plans; this product owns the adapter process and JSON-RPC connection.

Key guides:

- Product selection: `Docs/Guides/PRODUCT-SELECTION.md`
- API stability: `Docs/Guides/API-STABILITY.md`
- Phase notes: `Docs/Architecture/PHASE13-NOTES.md`

## Topics

- `DebugAdapterPool`
- `DebugAdapterSession`
- Transport and framing
- Mock debug adapter

## See Also

- Architecture notes under `Docs/Architecture/`
