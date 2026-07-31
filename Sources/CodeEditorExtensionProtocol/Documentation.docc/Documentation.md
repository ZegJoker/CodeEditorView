# ``CodeEditorExtensionProtocol``

Versioned CBOR wire protocol for CodeEditorView extension host ↔ guest.

## Overview

Canonical framing is a 4-byte big-endian length prefix plus a CBOR envelope.
JSON is available only as a diagnostic renderer.

Schema methods are listed in ``ExtensionMethodCatalog``; the handshake carries the schema hash.
