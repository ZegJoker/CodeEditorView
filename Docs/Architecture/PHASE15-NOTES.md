# Phase 15 notes — Platform qualification

## Goal

Each shipping configuration (direct-macOS, Mac App Store, iOS, enterprise, test) exposes **only** its approved capabilities, with real install/runtime gates, bundled-Wasm qualification, native helper policy, remote tooling fallback, and App Review documentation — **no soft-stubs**.

## Profiles

| ID | Code entry points |
|---|---|
| A direct-macos | `PlatformCapabilityProfile.directMacOS`, `ExtensionExecutionPolicy.shipping(.directMacOS)` |
| B mac-app-store | `.macAppStore` / `.shipping(.macAppStore)` |
| C ios | `.iOS` / `.shipping(.iOS)` |
| D enterprise | `.enterprise` + `EnterpriseProfileOptions` |
| E test | `.test` / `.shipping(.test)` |

Matrix fixture: `Tests/Fixtures/Profiles/matrix.json`  
Check script: `./scripts/check-feature-profiles.sh`

## New capability kinds

`bundledWasm`, `downloadableWasm`, `dynamicExtensionInstall`, `remoteTooling`, `extensionRegistry`

## Components

| Piece | Module |
|---|---|
| `ShippingProfileID`, expanded matrix | Core |
| `ExtensionHostProfile`, install/runnability DTOs | ExtensionAPI |
| `ShippingInstallPolicy` on package manager | Extensions |
| `ExtensionExecutionPolicy.shipping`, RuntimeSelector gates | Host |
| `NativeHelperLaunchPolicy` | Host |
| `RemoteToolingCoordinator` | Host |
| `ArtifactRunnability` | ExtensionAPI |
| `APP-REVIEW.md` | Docs |

## Gates (fail-closed)

1. **Install:** native marker / downloadable Wasm denied on MAS/iOS.
2. **RuntimeSelector:** native denied when profile disallows; downloadable Wasm denied; bundled Wasm allowed on MAS/iOS.
3. **Native prepare/start:** `NativeHelperLaunchPolicy` + trust.
4. **Language server:** `RemoteToolingCoordinator` → remote fallback when LS is not local.
5. **Enterprise:** `requireSignedNativeHelpers` denies workspace-dev natives.

## Soft-stub ban

| Forbidden | Actual |
|---|---|
| Docs-only MAS deny | Code on install + selector + driver |
| Remote fallback TODO | Coordinator + LS executor + tests |
| Bundled == download Wasm | `ExtensionArtifactOrigin` |
| Enterprise == directMacOS | `EnterpriseProfileOptions` |
| Profile enum unused | Wired into policy factories |

## Verification

```bash
swift test --filter Phase15
swift test --filter "Platform capabilities"
./scripts/check-feature-profiles.sh
./scripts/check-product-isolation.sh
./scripts/check-docs.sh
```
