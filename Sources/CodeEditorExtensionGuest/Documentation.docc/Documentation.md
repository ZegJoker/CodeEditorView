# ``CodeEditorExtensionGuest``

Swift guest runtime for native-process extensions.

## Overview

Link this product from a Swift executable extension. Call ``ExtensionGuestMain/run(extension:)``
or construct ``ExtensionGuestRuntime`` over stdio / test transports.

Depends only on `CodeEditorExtensionAPI` and `CodeEditorExtensionProtocol`.
