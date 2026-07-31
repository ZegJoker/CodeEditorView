# ``CodeEditorExtensions``

In-process extension runtime, host façade, and package lifecycle.

## Overview

Host-facing extension product. Re-exports ``CodeEditorExtensionAPI`` for compatibility.
Prefer authoring against the API product; use this module for:

- ``ExtensionRuntime`` lifecycle
- Contribution registrars and stores
- ``ExtensionPackageManager`` install/reload
- ``DataExtensionLoader`` legacy adapter

See `Docs/Architecture/PHASE9-NOTES.md` and `Docs/Guides/EXTENSION-AUTHORING.md`.

## Topics

- Runtime: ``ExtensionRuntime``, ``ExtensionContext``
- Package manager: ``ExtensionPackageManager``
- Data loader: ``DataExtensionLoader``
- Stores and registrars

## See Also

- ``CodeEditorExtensionAPI``
- Architecture notes under `Docs/Architecture/`
