# Extension public-type inventory (Phase 0)

Inventory of types that will move into or be replaced by `CodeEditorExtensionAPI` (Phase 9) vs remain host/façade-only.

Status legend: **API** = author-facing; **Host** = host implementation; **Both** = shared value model with host-only methods later; **Legacy** = migrate away.

## CodeEditorExtensions (current)

| Type | File | Phase 9 fate |
|---|---|---|
| `ExtensionID` | ExtensionIdentity.swift | **API** |
| `SemanticVersion` | ExtensionIdentity.swift | **API** (or shared value module) |
| `VersionRange` | ExtensionIdentity.swift | **API** |
| `ExtensionActivationEvent` | ExtensionManifest.swift | **API** |
| `HostCapability` | ExtensionManifest.swift | **API** → expand to typed `CapabilityRequest` |
| `ExtensionPermission` | ExtensionManifest.swift | **API** → capabilities model |
| `ExtensionManifest` | ExtensionManifest.swift | **Both** → TOML-validated model supersedes flat Codable |
| `HostEnvironment` | ExtensionManifest.swift | **API** (profile-aware) |
| `ExtensionError` | ExtensionManifest.swift | **API** |
| `CodeEditorExtension` | ExtensionContext.swift | **API** (`EditorExtension`) |
| `ExtensionContext` | ExtensionContext.swift | **API** (capability handles) |
| `ExtensionDisposable` | ExtensionDisposable.swift | **API** |
| `ExtensionRegistrationToken` | ExtensionDisposable.swift | **API** / internal lease |
| `CompositeExtensionDisposable` | ExtensionDisposable.swift | **API** |
| `ExtensionInactiveReason` | ExtensionStatus.swift | **Both** |
| `ExtensionState` | ExtensionStatus.swift | **Both** / lifecycle enum |
| `ExtensionStatus` | ExtensionStatus.swift | **Host** façade (Extensions product) |
| `ExtensionLogLevel` / `ExtensionLogEvent` / `ExtensionLog` | ExtensionStatus.swift | **API** log surface; host-owned buffer |
| `ExtensionHostServices` | ExtensionHostServices.swift | **Host** → brokered services, not ambient registries |
| `ExtensionRuntime` | ExtensionRuntime.swift | **Host** orchestrator |
| `ExtensionStorage` | ExtensionStorage.swift | **API** via private storage handle |
| `CommandContributionRegistrar` | ContributionRegistrars.swift | **API** command descriptors + registration |
| `KeybindingContributionRegistrar` | ContributionRegistrars.swift | **API** / data contributions |
| `LanguageContributionRegistrar` | ContributionRegistrars.swift | **API** |
| `LanguageServiceContributionRegistrar` | ContributionRegistrars.swift | **API** |
| `PanelContributionRegistrar` | ContributionRegistrars.swift | **API** declarative UI descriptors |
| `ThemeContributionRegistrar` | ContributionRegistrars.swift | **API** / data |
| `SnippetContributionRegistrar` | ContributionRegistrars.swift | **API** / data |
| `PanelContribution` / store | ContributionStores.swift | **Both** values; immutable registries replace mutable stores |
| `ThemeContribution` / store | ContributionStores.swift | **Both** |
| `SnippetContribution` / store | ContributionStores.swift | **Both** |
| `LanguageDefinitionDTO` | ContributionStores.swift | **API** / data schema |
| `DataExtensionBundle` / `DataExtensionLoader` | DataExtensionLoader.swift | **Legacy** JSON → TOML loader + migrate CLI |
| `KeybindingOverrideDTO` | DataExtensionLoader.swift | **API** / data |

## CodeEditorExtensionHost (current)

| Type | File | Phase 9–10 fate |
|---|---|---|
| `RemoteExtensionHost` | RemoteExtensionHost.swift | **Host** → multi-driver orchestrator |
| `ExtensionManagerModel` | ExtensionManagerModel.swift | **Host** / Workbench-facing UI model |
| `RemoteExtensionLaunch` / `RemoteExtensionDescriptor` | RemoteExtensionDiscovery.swift | **Host** package artifacts |
| `RemoteExtensionDiscovery` | RemoteExtensionDiscovery.swift | **Host** store discovery |
| `ExtensionProcessState` / `RemoteExtensionStatus` | RemoteExtensionDiscovery.swift | **Host** |
| `RemoteExtensionHostPolicy` | RemoteExtensionDiscovery.swift | **Host** platform policy |
| `RemoteExtensionProcess` | RemoteExtensionProcess.swift | **Host** native driver seed |
| `RemoteExtensionTransport` / process transport | Transport/ | **Host** framed transport |
| `RemoteExtensionServer` | RemoteExtensionServer.swift | **Host** → generated guest runtime |
| `ExtensionRPC*` types | RPC/ | **Host** internal → versioned protocol (CBOR) |
| `ExtensionRPCFraming` | RPCFraming.swift | **Host** internal |
| `ExtensionRPCConnection` | ExtensionRPCConnection.swift | **Host** internal |
| `RemoteLanguageServiceProviders` | Adapters/ | **Host** adapter to LanguageServices |

## Author-facing dependency rule (target)

```text
Extension package
  └── CodeEditorExtensionAPI   (+ CodeEditorExtensionTesting for tests)
        └── compact value models (Core / Documents / Commands / LanguageSupport / selected LanguageServices types)
```

Must **not** depend on: CodeEditorView, CodeEditorWorkbench, CodeEditorExtensionHost, Wasm engines, store implementation.

## Phase 9 status

1. **Done:** Extract protocols and value types into `CodeEditorExtensionAPI`.
2. **Done:** `@_exported import CodeEditorExtensionAPI` from `CodeEditorExtensions` for one major.
3. **Done:** `deactivate()` is async via protocol default.
4. **Done:** TOML packages + `ValidatedContributionPlan` + digests + package manager snapshots.
5. **Later:** Replace mutable optional registrars with capability-scoped handles (Phases 10+).
6. **Later:** `CodeEditorExtensionTesting` product.
