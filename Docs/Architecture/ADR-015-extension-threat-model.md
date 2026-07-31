# ADR-015: Extension threat model

## Status

Accepted (Phase 0)

## Context

Extensions will load declarative data and, on some profiles, executable code (in-process, native process, Swift-Wasm, or remote). Authority must be explicit. A native helper’s crash isolation is not the same as a security sandbox.

## Decision

### Authority intersection

Effective authority for every brokered operation is:

```text
manifest request
∩ publisher/store policy
∩ application policy
∩ platform capability
∩ workspace trust
∩ user grant
∩ runtime-specific restrictions
∩ per-request scope
```

A declaration is not a grant. Live grants are checked on every call with instance generation so stale handles fail after deactivate/restart.

### Runtime trust positions

| Runtime | Trust position |
|---|---|
| Built-in Swift | Trusted; same process; same crash domain as host |
| Data-only | No executable code; validate paths, size, and asset safety |
| Native Swift process | Reliability boundary only unless OS sandbox is active; **trusted-signed** or **workspace-dev** only by default; **untrusted** prohibited without audited sandbox |
| Swift-Wasm | Preferred technical sandbox; deny-by-default WASI; all external actions brokered |
| Remote provider | Host-mediated; credentials and network stay on the remote side under host policy |

### Fail closed

Reject activation (with actionable diagnostics) when:

- unknown manifest fields that affect authority
- incompatible API/protocol majors
- malformed packages or path escapes
- unsigned marketplace artifacts (when store policy requires signatures)
- denied or unconstrained capabilities required by contributions

### Capability classes (initial)

Typed requests include process exec, download, npm install, workspace read/write, private storage, source control, terminal, clipboard, secrets, UI contributions, and network HTTP—each with host/path/command constraints, never ambient `Process`/`URLSession`/shell.

### Secrets

Extensions use opaque secret references. Prefer injecting secrets into child processes or host HTTP requests rather than returning plaintext to the guest.

### Supply chain

Immutable version directories, SHA-256 file digests, signed packages, publisher identity, SBOM/licenses, quarantine over destructive delete, revocation lists. Dev/local builds may be unsigned but must be clearly marked.

### Adversarial coverage (program requirement)

TOML/CBOR/path/archive bombs, forged handles, capability bypass, Wasm loops and memory growth, native crash/hang/fork storms, stream floods, and update/revocation races are Phase 1+ CI/nightly fixtures (implemented with each runtime phase).

## Consequences

- Hosts must surface why an extension cannot run (missing runtime, denied capability, policy).
- Product docs state clearly that native helpers are not sandboxes.
- Security tests are part of Stable gates for Extensions and ExtensionHost.
