import CodeEditorDocuments
import Foundation
import Observation

/// Lazy in-memory cache of expanded workspace directories.
@MainActor
@Observable
public final class WorkspaceFileTree {
    public private(set) var roots: [WorkspaceRoot]
    private let fileSystem: any WorkspaceFileSystem
    /// Loaded children for expanded nodes. Missing key = not loaded.
    private var loadedChildren: [WorkspaceItemID: [WorkspaceItem]] = [:]
    private var expanded: Set<WorkspaceItemID> = []

    public init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
        self.roots = fileSystem.roots
    }

    public func refreshRoots() {
        roots = fileSystem.roots
    }

    public func isExpanded(_ id: WorkspaceItemID) -> Bool {
        expanded.contains(id)
    }

    public func isLoaded(_ id: WorkspaceItemID) -> Bool {
        loadedChildren[id] != nil
    }

    public func cachedChildren(of id: WorkspaceItemID) -> [WorkspaceItem]? {
        loadedChildren[id]
    }

    @discardableResult
    public func children(of id: WorkspaceItemID) async throws -> [WorkspaceItem] {
        if let cached = loadedChildren[id] {
            return cached
        }
        let kids = try await fileSystem.children(of: id)
        loadedChildren[id] = kids
        return kids
    }

    public func expand(_ id: WorkspaceItemID) async throws {
        _ = try await children(of: id)
        expanded.insert(id)
    }

    public func collapse(_ id: WorkspaceItemID) {
        expanded.remove(id)
        // Keep cache for faster re-expand; hosts may call invalidate if needed.
    }

    public func invalidate(_ id: WorkspaceItemID) {
        loadedChildren[id] = nil
    }

    public func invalidateAll() {
        loadedChildren.removeAll()
        expanded.removeAll()
    }

    public func apply(_ event: WorkspaceFileEvent) {
        switch event {
        case .rescanRequired:
            invalidateAll()
        case .rootAdded(let root):
            if !roots.contains(where: { $0.id == root.id }) {
                roots.append(root)
            }
        case .rootRemoved(let id):
            roots.removeAll { $0.id == id }
            loadedChildren = loadedChildren.filter { $0.key.rootID != id }
            expanded = expanded.filter { $0.rootID != id }
        case .added(let item):
            if let parentPath = item.id.parentPath {
                let parentID = WorkspaceItemID(rootID: item.id.rootID, path: parentPath)
                if var kids = loadedChildren[parentID] {
                    if !kids.contains(where: { $0.id == item.id }) {
                        kids.append(item)
                        kids.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        loadedChildren[parentID] = kids
                    }
                }
            } else {
                // Root-level file under a workspace root.
                let parentID = WorkspaceItemID(rootID: item.id.rootID, path: "")
                if var kids = loadedChildren[parentID] {
                    if !kids.contains(where: { $0.id == item.id }) {
                        kids.append(item)
                        kids.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        loadedChildren[parentID] = kids
                    }
                }
            }
        case .removed(let id):
            if let parentPath = id.parentPath {
                let parentID = WorkspaceItemID(rootID: id.rootID, path: parentPath)
                loadedChildren[parentID]?.removeAll { $0.id == id }
            } else {
                let parentID = WorkspaceItemID(rootID: id.rootID, path: "")
                loadedChildren[parentID]?.removeAll { $0.id == id }
            }
            loadedChildren[id] = nil
            expanded.remove(id)
        case .changed(let item):
            if let parentPath = item.id.parentPath {
                let parentID = WorkspaceItemID(rootID: item.id.rootID, path: parentPath)
                if let idx = loadedChildren[parentID]?.firstIndex(where: { $0.id == item.id }) {
                    loadedChildren[parentID]?[idx] = item
                }
            }
        case .renamed(let from, let to):
            apply(.removed(from))
            apply(.added(to))
        }
    }
}
