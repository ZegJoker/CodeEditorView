import Foundation
import Observation
import CodeEditorDocuments
import CodeEditorWorkspace

public struct OpenQuicklyItem: Identifiable, Hashable, Sendable {
    public var id: DocumentURI { uri }
    public var uri: DocumentURI
    public var name: String
    public var path: String

    public init(uri: DocumentURI, name: String, path: String) {
        self.uri = uri
        self.name = name
        self.path = path
    }
}

@MainActor
@Observable
public final class OpenQuicklyModel {
    public var query: String = "" {
        didSet { scheduleFilter() }
    }
    public private(set) var results: [OpenQuicklyItem] = []
    public private(set) var isScanning: Bool = false

    private var allItems: [OpenQuicklyItem] = []
    private var scanTask: Task<Void, Never>?
    public var resultLimit: Int = 50

    public init() {}

    public func recompute(workspace: Workspace) async {
        scanTask?.cancel()
        isScanning = true
        defer { isScanning = false }

        var collected: [OpenQuicklyItem] = []
        for root in workspace.fileSystem.roots {
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            try? await collectFiles(
                from: rootItem,
                rootName: root.name,
                workspace: workspace,
                into: &collected,
                depth: 0,
                maxDepth: 12
            )
            if Task.isCancelled { return }
        }
        allItems = collected
        applyFilter()
    }

    private func scheduleFilter() {
        applyFilter()
    }

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            results = Array(allItems.prefix(resultLimit))
            return
        }
        results = Array(
            allItems
                .filter {
                    $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)
                }
                .prefix(resultLimit)
        )
    }

    private func collectFiles(
        from item: WorkspaceItemID,
        rootName: String,
        workspace: Workspace,
        into collected: inout [OpenQuicklyItem],
        depth: Int,
        maxDepth: Int
    ) async throws {
        guard depth <= maxDepth, !Task.isCancelled else { return }
        let children = try await workspace.fileSystem.children(of: item)
        for child in children {
            if Task.isCancelled { return }
            if child.isDirectory {
                try await collectFiles(
                    from: child.id,
                    rootName: rootName,
                    workspace: workspace,
                    into: &collected,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
            } else {
                let displayPath = child.id.path.isEmpty ? child.name : "\(rootName)/\(child.id.path)"
                collected.append(
                    OpenQuicklyItem(uri: child.uri, name: child.name, path: displayPath)
                )
            }
        }
    }
}
