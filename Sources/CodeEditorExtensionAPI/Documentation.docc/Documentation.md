# ``CodeEditorExtensionAPI``

Transport-neutral Swift author surface for CodeEditorView extensions.

## Overview

Extension packages depend on this product only (not View, Workbench, or ExtensionHost).
Canonical packages use `extension.toml` with declarative contribution folders.

Authors implement ``EditorExtension`` / ``CodeEditorExtension`` and receive an
``ExtensionAuthorContext`` on activation. Hosts may provide a richer concrete context
with contribution registrars.

Use ``ExtensionPackageLoader`` to validate packages into a ``ValidatedContributionPlan``,
``ExtensionPackageDigest`` for canonical checksums, and ``ExtensionMigration`` for
JSON → TOML conversion.

## Topics

### Identity and versions

- ``ExtensionID``
- ``SemanticVersion``
- ``VersionRange``

### Manifest and activation

- ``ExtensionManifest``
- ``ExtensionActivationEvent``
- ``HostCapability``
- ``ExtensionPermission``
- ``HostEnvironment``
- ``ExtensionError``

### Author protocol

- ``CodeEditorExtension``
- ``EditorExtension``
- ``ExtensionAuthorContext``
- ``ExtensionDisposable``

### Contribution values

- ``ThemeContribution``
- ``SnippetContribution``
- ``IconThemeContribution``
- ``LanguageDefinitionDTO``
- ``GrammarContribution``
- ``QueryContribution``

### Package validation

- ``ExtensionTOMLParser``
- ``ExtensionPackageLoader``
- ``ValidatedContributionPlan``
- ``ImmutableContributionRegistry``
- ``ExtensionPackageDigest``
- ``ExtensionMigration``
