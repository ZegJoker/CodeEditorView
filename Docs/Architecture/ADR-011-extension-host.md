# ADR-011: Out-of-process extension host

## Status

Accepted (Phase 12)

## Context

Phase 9 provides a portable in-process extension runtime. Some extensions need process isolation (crash containment, separate privileges). Apple’s ExtensionKit/XPC is the platform vehicle on macOS, but a reusable library must not require private LaunchServices database mutation and must remain testable in CI without shipping `.appex` binaries.

## Decision

1. **`CodeEditorExtensionHost` product** depends on Extensions + Core/Documents/Commands/LanguageSupport/LanguageServices. It does not depend on View, Workbench, LSP, or tooling products.

2. **Versioned Codable RPC** (`ExtensionRPCProtocolVersion` major=1) with Content-Length framing. Handshake rejects incompatible majors and capability/API mismatches cleanly.

3. **Transport abstraction** with:
   - `MockRemoteExtensionTransport` (CI / in-process peer)
   - `ProcessRemoteExtensionTransport` (stdio helper)
   - Optional host-injected ExtensionKit/XPC connection (not auto-approved)

4. **Discovery is pluggable** (`RemoteExtensionDiscovery`). Default is static descriptors supplied by the app. No private LS registration APIs.

5. **Crash policy:** transport failure marks the process crashed, disposes remote LanguageServices registrations, and never mutates host documents. Optional auto-restart with caps.

6. **Remote adapters** implement Phase 8 provider protocols by calling RPC methods (`completion`, `hover`, `definition`, …).

7. **`ExtensionManagerModel`** exposes status for workbench UI without embedding SwiftUI in this product.

## Consequences

- In-process Phase 9 remains the portable default.
- Real ExtensionKit packaging stays an application concern; the library provides the host client, RPC, and safety policy.
- Tests use mock transports and `RemoteExtensionServer` peers.
