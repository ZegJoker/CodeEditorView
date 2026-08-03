import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Cancellable workspace file index for Open Quickly / project views.
public protocol WorkspaceIndexService: AnyObject, Sendable {
    @MainActor
    func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem]
}

/// Immutable snapshot of a file-tree index generation (WB-N04).
public struct FileTreeIndexSnapshot: Sendable, Hashable {
    public var generation: UInt64
    public var items: [OpenQuicklyItem]

    public init(generation: UInt64, items: [OpenQuicklyItem]) {
        self.generation = generation
        self.items = items
    }
}

/// Background actor that walks the filesystem without touching the MainActor file tree (WB-N04).
///
/// Uses ``WorkspaceFileSystem`` listing only — never ``WorkspaceFileTree/expand`` — so Open Quickly
/// indexing cannot freeze the UI or force-expand the project navigator.
public actor FileTreeIndexEngine {
    public var maxDepth: Int
    public var maxFiles: Int
    public var ignoredDirectoryNames: Set<String>
    /// Batch size when yielding partial results to the UI (bounded).
    public var batchSize: Int
    public private(set) var generation: UInt64 = 0

    public init(
        maxDepth: Int = 12,
        maxFiles: Int = 20_000,
        ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"],
        batchSize: Int = 256
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.batchSize = max(1, batchSize)
    }

    /// Full rebuild from the workspace filesystem (off MainActor).
    public func rebuild(fileSystem: any WorkspaceFileSystem) async throws -> [OpenQuicklyItem] {
        generation &+= 1
        var collected: [OpenQuicklyItem] = []
        collected.reserveCapacity(min(1024, maxFiles))
        let roots = await fileSystem.roots
        for root in roots {
            try Task.checkCancellation()
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            try await collect(
                from: rootItem,
                rootName: root.name,
                fileSystem: fileSystem,
                into: &collected,
                depth: 0
            )
            if collected.count >= maxFiles { break }
        }
        if collected.count > maxFiles {
            collected = Array(collected.prefix(maxFiles))
        }
        return collected
    }

    /// Rebuild and return an immutable snapshot with generation.
    public func rebuildSnapshot(fileSystem: any WorkspaceFileSystem) async throws -> FileTreeIndexSnapshot {
        let items = try await rebuild(fileSystem: fileSystem)
        return FileTreeIndexSnapshot(generation: generation, items: items)
    }

    private func collect(
        from item: WorkspaceItemID,
        rootName: String,
        fileSystem: any WorkspaceFileSystem,
        into collected: inout [OpenQuicklyItem],
        depth: Int
    ) async throws {
        try Task.checkCancellation()
        if depth > maxDepth || collected.count >= maxFiles { return }

        // Direct filesystem listing — not MainActor WorkspaceFileTree.
        let children = try await fileSystem.children(of: item)
        var batchCount = 0
        for child in children {
            try Task.checkCancellation()
            if collected.count >= maxFiles { return }
            if ignoredDirectoryNames.contains(child.name) { continue }
            if child.isDirectory {
                try await collect(
                    from: child.id,
                    rootName: rootName,
                    fileSystem: fileSystem,
                    into: &collected,
                    depth: depth + 1
                )
            } else {
                let uri = child.uri
                let path = child.id.path.isEmpty ? child.name : "\(rootName)/\(child.id.path)"
                collected.append(OpenQuicklyItem(uri: uri, name: child.name, path: path))
                batchCount += 1
                // Cooperative yield every batch so cancellation is responsive on large trees.
                if batchCount % batchSize == 0 {
                    await Task.yield()
                }
            }
        }
    }
}

/// Default index service: background ``FileTreeIndexEngine`` + MainActor delivery (WB-N04).
public final class FileTreeIndexService: WorkspaceIndexService, @unchecked Sendable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var ignoredDirectoryNames: Set<String>
    private let engine: FileTreeIndexEngine

    public init(
        maxDepth: Int = 12,
        maxFiles: Int = 20_000,
        ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"]
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.engine = FileTreeIndexEngine(
            maxDepth: maxDepth,
            maxFiles: maxFiles,
            ignoredDirectoryNames: ignoredDirectoryNames
        )
    }

    @MainActor
    public func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem] {
        // Capture filesystem reference on MainActor, walk on the engine actor.
        let fileSystem = workspace.fileSystem
        // Keep engine knobs in sync with public vars (tests may mutate after init).
        await engine.setLimits(
            maxDepth: maxDepth,
            maxFiles: maxFiles,
            ignoredDirectoryNames: ignoredDirectoryNames
        )
        return try await engine.rebuild(fileSystem: fileSystem)
    }
}

extension FileTreeIndexEngine {
    fileprivate func setLimits(
        maxDepth: Int,
        maxFiles: Int,
        ignoredDirectoryNames: Set<String>
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }
}
