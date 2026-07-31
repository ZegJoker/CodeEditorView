import Foundation
import CodeEditorDocuments

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

    public init(level: WorkspaceTrust = .trusted, trustedRootIDs: Set<WorkspaceRootID> = []) {
        self.level = level
        self.trustedRootIDs = trustedRootIDs
    }

    public static let `default` = WorkspaceTrustState()
}

/// Abstract multi-root workspace file system with lazy children and event stream.
public protocol WorkspaceFileSystem: Sendable {
    var roots: [WorkspaceRoot] { get }

    func children(of item: WorkspaceItemID) async throws -> [WorkspaceItem]
    func item(for uri: DocumentURI) -> WorkspaceItem?
    func uri(for item: WorkspaceItemID) -> DocumentURI?

    func createFile(in parent: WorkspaceItemID, name: String, contents: Data) async throws -> WorkspaceItem
    func createDirectory(in parent: WorkspaceItemID, name: String) async throws -> WorkspaceItem
    func move(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    func copy(item: WorkspaceItemID, to parent: WorkspaceItemID, newName: String?) async throws -> WorkspaceItem
    func delete(item: WorkspaceItemID) async throws

    func addRoot(directoryURL: URL) async throws -> WorkspaceRoot
    func removeRoot(id: WorkspaceRootID) async throws

    func events() -> AsyncThrowingStream<WorkspaceFileEvent, Error>
}

public struct WorkspaceSettings: Sendable, Hashable, Codable {
    /// Directory/file names to hide from listings (default includes `.git`).
    public var excludedNames: Set<String>
    public var followSymlinks: Bool

    public init(
        excludedNames: Set<String> = [".git", ".DS_Store"],
        followSymlinks: Bool = false
    ) {
        self.excludedNames = excludedNames
        self.followSymlinks = followSymlinks
    }

    public static let `default` = WorkspaceSettings()
}
