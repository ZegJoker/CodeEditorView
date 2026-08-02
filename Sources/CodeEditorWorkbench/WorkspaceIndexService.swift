import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Cancellable workspace file index for Open Quickly / project views.
public protocol WorkspaceIndexService: AnyObject, Sendable {
    @MainActor
    func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem]
}

/// Default index: walks the workspace file tree with depth/budget and cancellation.
public final class FileTreeIndexService: WorkspaceIndexService, @unchecked Sendable {
    public var maxDepth: Int
    public var maxFiles: Int
    public var ignoredDirectoryNames: Set<String>

    public init(
        maxDepth: Int = 12,
        maxFiles: Int = 20_000,
        ignoredDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"]
    ) {
        self.maxDepth = maxDepth
        self.maxFiles = maxFiles
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }

    @MainActor
    public func rebuild(workspace: Workspace) async throws -> [OpenQuicklyItem] {
        var collected: [OpenQuicklyItem] = []
        collected.reserveCapacity(min(1024, maxFiles))
        for root in await workspace.fileSystem.roots {
            try Task.checkCancellation()
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            try await collect(
                from: rootItem,
                rootName: root.name,
                workspace: workspace,
                into: &collected,
                depth: 0
            )
            if collected.count >= maxFiles { break }
        }
        return collected
    }

    @MainActor
    private func collect(
        from item: WorkspaceItemID,
        rootName: String,
        workspace: Workspace,
        into collected: inout [OpenQuicklyItem],
        depth: Int
    ) async throws {
        try Task.checkCancellation()
        if depth > maxDepth || collected.count >= maxFiles { return }

        try await workspace.fileTree.expand(item)
        let children = try await workspace.fileTree.children(of: item)
        for child in children {
            try Task.checkCancellation()
            if collected.count >= maxFiles { return }
            if ignoredDirectoryNames.contains(child.name) { continue }
            if child.isDirectory {
                try await collect(
                    from: child.id,
                    rootName: rootName,
                    workspace: workspace,
                    into: &collected,
                    depth: depth + 1
                )
            } else {
                let uri = child.uri
                let path = child.id.path.isEmpty ? child.name : "\(rootName)/\(child.id.path)"
                collected.append(OpenQuicklyItem(uri: uri, name: child.name, path: path))
            }
        }
    }
}
