import SwiftUI
import CodeEditorDocuments
import CodeEditorWorkspace

/// Lazy file-tree navigator bound to ``Workspace/fileTree``.
public struct WorkspaceFileTreeView: View {
    @Bindable var model: WorkbenchModel
    @State private var expansion: Set<String> = []
    @State private var childrenCache: [String: [WorkspaceItem]] = [:]
    @State private var loadError: String?

    public init(model: WorkbenchModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Explorer")
                .font(.headline)
                .padding(8)
            Divider()
            List {
                ForEach(model.workspace.fileTree.roots, id: \.id.rawValue) { root in
                    DisclosureGroup(
                        isExpanded: expansionBinding(for: rootKey(root.id))
                    ) {
                        childrenList(for: WorkspaceItemID(rootID: root.id, path: ""))
                    } label: {
                        Label(root.name, systemImage: "folder.fill")
                    }
                }
            }
            .listStyle(.sidebar)
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
        .task(id: expansion) {
            await loadExpandedNodes()
        }
    }

    private func childrenList(for parent: WorkspaceItemID) -> AnyView {
        let key = itemKey(parent)
        let kids = childrenCache[key] ?? []
        return AnyView(
            ForEach(kids, id: \.id.path) { item in
                if item.isDirectory {
                    DisclosureGroup(isExpanded: expansionBinding(for: itemKey(item.id))) {
                        childrenList(for: item.id)
                    } label: {
                        Label(item.name, systemImage: "folder")
                    }
                } else {
                    Button {
                        model.openURI(item.uri, preview: true)
                    } label: {
                        Label(item.name, systemImage: "doc")
                    }
                    .buttonStyle(.plain)
                }
            }
        )
    }

    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expansion.contains(key) },
            set: { expanded in
                if expanded {
                    expansion.insert(key)
                } else {
                    expansion.remove(key)
                }
            }
        )
    }

    private func rootKey(_ id: WorkspaceRootID) -> String {
        "root:\(id.rawValue.uuidString)"
    }

    private func itemKey(_ id: WorkspaceItemID) -> String {
        "\(id.rootID.rawValue.uuidString)/\(id.path)"
    }

    private func loadExpandedNodes() async {
        loadError = nil
        for root in model.workspace.fileTree.roots {
            let rootItem = WorkspaceItemID(rootID: root.id, path: "")
            let key = itemKey(rootItem)
            if expansion.contains(rootKey(root.id)) || expansion.contains(key) {
                await loadChildren(rootItem)
            }
        }
        // Load any expanded paths
        for key in expansion where key.contains("/") {
            // Parse rootUUID/path
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let uuid = UUID(uuidString: parts[0])
            else { continue }
            let item = WorkspaceItemID(rootID: WorkspaceRootID(rawValue: uuid), path: parts[1])
            await loadChildren(item)
        }
    }

    private func loadChildren(_ id: WorkspaceItemID) async {
        do {
            try await model.workspace.fileTree.expand(id)
            let kids = try await model.workspace.fileTree.children(of: id)
            childrenCache[itemKey(id)] = kids
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Built-in contribution

@MainActor
final class FileTreeNavigatorContribution: WorkbenchContribution {
    let id = "workbench.navigator.files"
    let slot: WorkbenchSlot = .navigator
    let priority = 100
    let title = "Files"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkspaceFileTreeView(model: context.model))
    }
}

@MainActor
final class StatusBarContribution: WorkbenchContribution {
    let id = "workbench.status.default"
    let slot: WorkbenchSlot = .statusBar
    let priority = 100
    let title = "Status"

    func makeBody(context: WorkbenchContributionContext) -> AnyView {
        AnyView(WorkbenchStatusBar(model: context.model))
    }
}

struct WorkbenchStatusBar: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        HStack(spacing: 12) {
            if let doc = model.activeDocument {
                Text(doc.uri.fileURL?.lastPathComponent ?? doc.uri.rawValue)
                if doc.isDirty {
                    Text("●").foregroundStyle(.orange)
                }
                Text("v\(doc.version.rawValue)")
                    .foregroundStyle(.secondary)
            } else {
                Text("No file")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
