import CodeEditorDocuments
import Foundation

public enum WorkspaceFileEvent: Sendable, Hashable {
    case added(WorkspaceItem)
    case removed(WorkspaceItemID)
    case changed(WorkspaceItem)
    case renamed(from: WorkspaceItemID, to: WorkspaceItem)
    case rootAdded(WorkspaceRoot)
    case rootRemoved(WorkspaceRootID)
    /// Watcher overflow or coalesced burst; clients should full-rescan.
    case rescanRequired(WorkspaceRootID?)
}

public enum WorkspaceFileSystemError: Error, Sendable, Equatable {
    case rootNotFound
    case itemNotFound(String)
    case notADirectory
    case alreadyExists(String)
    case ioFailure(String)
    case invalidName
    case pathEscapesRoot(String)
}

/// Whether the workspace is trusted for process-backed tooling.
public enum WorkspaceTrust: String, Sendable, Hashable, Codable, CaseIterable {
    /// Full local tooling allowed (subject to platform profile).
    case trusted
    /// Restricted: prefer no ambient process launch without prompts.
    case restricted
    /// Explicitly untrusted (browser-like).
    case untrusted
}

public struct WorkspaceTrustState: Sendable, Hashable, Codable {
    public var level: WorkspaceTrust
    public var trustedRootIDs: Set<WorkspaceRootID>

    /// Defaults to **restricted** — never assume a newly opened workspace is trusted (audit §8.7).
    public init(level: WorkspaceTrust = .restricted, trustedRootIDs: Set<WorkspaceRootID> = []) {
        self.level = level
        self.trustedRootIDs = trustedRootIDs
    }

    /// Fail-closed default: restricted until the host promotes trust.
    public static let `default` = WorkspaceTrustState(level: .restricted)
    /// Explicit fully trusted state for known-safe host workflows.
    public static let trusted = WorkspaceTrustState(level: .trusted)
}

/// Abstract multi-root workspace file system with lazy children and event stream.
///
/// Implementations must isolate mutable watch/root state (prefer `actor`) so the
/// type is safely `Sendable` without `@unchecked` (audit §8.4 / WSP-004).
public protocol WorkspaceFileSystem: Sendable {
    var roots: [WorkspaceRoot] { get async }

    func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem]
    func item(for uri: DocumentURI) async -> WorkspaceItem?
    func uri(for item: WorkspaceItemID) async -> DocumentURI?

    func createFile(in parent: WorkspaceItemID, name: String, contents: Data) async throws -> WorkspaceItem
    func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem
    func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    func delete(item: WorkspaceItemID) async throws

    func addRoot(directoryURL: URL) async throws -> WorkspaceRoot
    func removeRoot(id: WorkspaceRootID) async throws

    func events() async -> AsyncThrowingStream<WorkspaceFileEvent, Error>
}

public struct WorkspaceSettings: Sendable, Hashable, Codable {
    /// Directory/file names to hide from listings (default includes `.git`).
    public var excludedNames: Set<String>
    public var followSymlinks: Bool
    /// Default excluded watch directories (WSP-005).
    public var watchExcludedNames: Set<String>
    /// Path resolve options for security checks.
    public var pathResolveOptions: WorkspacePathResolveOptions

    public init(
        excludedNames: Set<String> = [".git", ".DS_Store"],
        followSymlinks: Bool = false,
        watchExcludedNames: Set<String> = [".git", "node_modules", ".build", "DerivedData"],
        pathResolveOptions: WorkspacePathResolveOptions = .default
    ) {
        self.excludedNames = excludedNames
        self.followSymlinks = followSymlinks
        self.watchExcludedNames = watchExcludedNames
        self.pathResolveOptions = pathResolveOptions
    }

    public static let `default` = WorkspaceSettings()
}

/// Capability gates controlled by workspace trust (audit §8.7).
public enum WorkspaceTrustCapability: String, Sendable, Hashable, CaseIterable {
    case taskExecution
    case localProcess
    case pty
    case extensionActivation
    case languageServerLaunch
    case gitHooks
    case debugAdapter
    case mcpAgent
    case terminalShellIntegration
}

extension WorkspaceTrustState {
    /// Whether a capability is allowed under the current trust level.
    public func allows(_ capability: WorkspaceTrustCapability) -> Bool {
        switch level {
        case .trusted:
            return true
        case .restricted, .untrusted:
            // Fail closed for process/network-adjacent capabilities.
            switch capability {
            case .taskExecution, .localProcess, .pty, .extensionActivation,
                .languageServerLaunch, .gitHooks, .debugAdapter, .mcpAgent,
                .terminalShellIntegration:
                return false
            }
        }
    }

    /// Promote trust for explicit host decisions (never ambient).
    public mutating func promote(to level: WorkspaceTrust) {
        self.level = level
    }
}
