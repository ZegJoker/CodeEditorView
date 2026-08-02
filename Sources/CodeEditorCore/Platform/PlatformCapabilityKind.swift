/// Named capabilities that products must query before assuming OS support.
public enum PlatformCapabilityKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Generic local subprocess launch (`Foundation.Process`) with argv — never shell.
    case localProcess
    /// High-trust shell execution (`/bin/sh -c`) — CORE-N04; not implied by `localProcess`.
    case localShellExecution
    /// Pseudo-terminal sessions.
    case localPTY
    /// Local `git` CLI (or equivalent) for source control.
    case localGitCLI
    /// Local language-server process (stdio LSP).
    case localLanguageServerProcess
    /// Native Swift extension helper process.
    case nativeExtensionProcess
    /// Outbound network client (downloads, registry).
    case networkClient
    /// Workspace filesystem access on the host.
    case workspaceFilesystem
    /// App-bundled Swift-Wasm modules shipped inside the binary.
    case bundledWasm
    /// Marketplace / post-install downloadable Wasm artifacts.
    case downloadableWasm
    /// Install of new extension package trees at runtime.
    case dynamicExtensionInstall
    /// Remote LS / DAP / MCP / extension providers.
    case remoteTooling
    /// Fetch remote extension registry/index.
    case extensionRegistry
}
