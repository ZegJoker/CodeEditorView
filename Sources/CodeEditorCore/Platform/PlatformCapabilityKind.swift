/// Named capabilities that products must query before assuming OS support.
public enum PlatformCapabilityKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Generic local subprocess launch (`Foundation.Process`).
    case localProcess
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
}
